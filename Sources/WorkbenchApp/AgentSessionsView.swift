import AppKit
import SwiftUI
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class AgentSessionsModel: ObservableObject {
    @Published var listing: AgentSessionListing?
    @Published var directory = ""
    @Published var tool: CodingAgent = .claude
    @Published var selection: String?
    @Published var search = ""
    @Published var busy = false
    @Published var failure: String?
    @Published var target: AgentExecutionTarget?
    @Published var tmuxPanes: [TmuxPane] = []
    private weak var workspace: Workspace?
    private let source: TerminalSession?
    private let connection: UUID?
    private var cancellation = CancellationFlag()
    private var generation = UUID()
    private var cachedListings: [CodingAgent: AgentSessionListing] = [:]
    init(workspace: Workspace) {
        self.workspace = workspace; source = workspace.selectedTerminal; connection = source?.connectionID
        tool = source?.agentLaunch?.1.tool ?? .claude
    }
    var records: [AgentSessionRecord] {
        (listing?.sessions ?? []).filter { $0.tool == tool && (search.isEmpty || ($0.title + $0.directory + $0.tool.title + $0.sessionID).localizedCaseInsensitiveContains(search)) }
            .sorted { left, right in
                if left.activityDate != right.activityDate { return left.activityDate > right.activityDate }
                return left.sessionID < right.sessionID
            }
    }
    var selected: AgentSessionRecord? { records.first { $0.id == selection } }
    var running: [TerminalSession] {
        guard let workspace, let target else { return [] }
        return workspace.sessions.filter { $0.connected && $0.agentLaunch?.0.target.identity == target.identity && $0.agentLaunch?.1.tool == tool }
    }
    func stop() { cancellation.cancel(); generation = UUID(); busy = false }
    private func validateSource() async throws {
        guard let source, source.connected, source.connectionID == connection, source.connectionConfigurationValid() else {
            throw WorkbenchError.message(L10n.text("原终端连接已变化，请重新打开 Agent 会话面板。"))
        }
        if case .docker(let binding) = target, let workspace, let tmux = source.tmuxID {
            let transport = workspace.store.transport
            let current = try await Task.detached { try TmuxService(transport: transport, host: nil).localDockerTerminal(session: tmux) }.value
            guard current == binding.terminal else { throw WorkbenchError.message(L10n.text("Docker 进程或原 tmux 窗格已变化，请重新确认容器。")) }
        } else if let tmux = source.tmuxID, let workspace {
            let service = TmuxService(transport: workspace.store.transport, host: source.host)
            let pane = try await Task.detached { try service.attachmentTarget(session: tmux) }.value
            guard !["ssh", "mosh", "docker", "podman", "sudo", "su"].contains(pane.command) else { throw WorkbenchError.message(L10n.text("当前执行环境未确认，请使用实际主机或容器连接。")) }
        } else if source.isLocal {
            let command = try AgentSessionCatalog.localForegroundCommand(shellPID: source.terminal.process.shellPid)
            guard !["ssh", "mosh", "docker", "podman", "sudo", "su"].contains(command) else { throw WorkbenchError.message(L10n.text("当前执行环境未确认，请使用实际主机或容器连接。")) }
        }
    }
    func refresh() async {
        stop(); busy = true; failure = nil
        let selectedTool = tool
        listing = cachedListings[selectedTool]; selection = nil
        let flag = CancellationFlag(); cancellation = flag
        let request = UUID(); generation = request
        defer { if generation == request { busy = false } }
        do {
            guard let workspace, let source, source.connected, source.connectionID == connection, source.connectionConfigurationValid() else {
                throw WorkbenchError.message(L10n.text("原终端连接已变化，请重新打开 Agent 会话面板。"))
            }
            let transport = workspace.store.transport
            if target == nil {
                if let managed = source.agentLaunch {
                    if case .docker(let original) = managed.0.target, let tmux = source.tmuxID {
                        let binding = try await Task.detached {
                            let terminal = try TmuxService(transport: transport, host: nil).localDockerTerminal(session: tmux)
                            try original.daemon.validate(original, cancellation: flag)
                            return try original.daemon.confirm(original.container.id, terminal: terminal, cancellation: flag)
                        }.value
                        guard generation == request, !flag.isCancelled else { return }
                        target = .docker(binding)
                    } else { target = managed.0.target }
                    directory = managed.1.directory
                }
                else if let tmux = source.tmuxID {
                    let host = source.host
                    let pane = try await Task.detached { try TmuxService(transport: transport, host: host).attachmentTarget(session: tmux) }.value
                    if host == nil && pane.command == "docker" {
                        let terminal = try await Task.detached { try TmuxService(transport: transport, host: nil).localDockerTerminal(session: tmux) }.value
                        let discovered = try await Task.detached { try DockerAttachmentDaemon.discover(terminal: terminal, cancellation: flag) }.value
                        guard generation == request, !flag.isCancelled else { return }
                        guard confirm(L10n.text("在此容器查看 Agent 会话？"), L10n.text("将以原 Docker 用户读取工具状态。容器：") + (discovered.containers.first { $0.id == discovered.detectedContainerID }?.displayName ?? discovered.detectedContainerID) + "\n" + L10n.text("若容器内再次 SSH 或切换用户，请取消。")) else { return }
                        let binding = try await Task.detached { try discovered.daemon.confirm(discovered.detectedContainerID, terminal: terminal, cancellation: flag) }.value
                        target = .docker(binding)
                    } else {
                        guard !["ssh", "mosh", "docker", "podman", "sudo", "su"].contains(pane.command) else { throw WorkbenchError.message(L10n.text("当前执行环境未确认，请使用实际主机或容器连接。")) }
                        target = host.map(AgentExecutionTarget.ssh) ?? .local; directory = pane.directory
                    }
                } else {
                    if source.isLocal {
                        let command = try AgentSessionCatalog.localForegroundCommand(shellPID: source.terminal.process.shellPid)
                        guard !["ssh", "mosh", "docker", "podman", "sudo", "su"].contains(command) else { throw WorkbenchError.message(L10n.text("当前执行环境未确认，请使用实际主机或容器连接。")) }
                    }
                    target = source.host.map(AgentExecutionTarget.ssh) ?? .local
                    directory = source.reportedDirectory ?? ""
                }
            }
            guard let target else { return }
            try await validateSource()
            guard generation == request, !flag.isCancelled else { return }
            let catalog = AgentSessionCatalog(target: target, transport: transport)
            let result = try await Task.detached { try catalog.list(history: true, tool: selectedTool, cancellation: flag) }.value
            try await validateSource()
            guard generation == request, !flag.isCancelled else { return }
            cachedListings[selectedTool] = result; listing = result
            if directory.isEmpty { directory = result.home }
            if case .docker = target { tmuxPanes = [] }
            else {
                let panes = await Task.detached { (try? TmuxService(transport: transport, host: target.host).panes()) ?? [] }.value
                guard generation == request, !flag.isCancelled else { return }
                tmuxPanes = panes.filter { $0.command == selectedTool.rawValue }
            }
        } catch { if generation == request, !flag.isCancelled { failure = error.localizedDescription } }
    }
    func launch(_ action: AgentLaunchAction) async -> Bool {
        guard !busy, let workspace, let source, let target else { return false }
        let request = generation
        busy = true; failure = nil; defer { if generation == request { busy = false } }
        do {
            try await validateSource()
            guard generation == request, !cancellation.isCancelled else { return false }
            let chosen: CodingAgent
            let cwd: String
            if case .resume(let record) = action { chosen = record.tool; cwd = record.directory }
            else { chosen = tool; cwd = directory }
            guard let executable = action == .shell ? "/bin/sh" : listing?.tools.first(where: { $0.tool == chosen })?.executable else { throw WorkbenchError.message(L10n.text("当前设备未检测到该工具。请先自行安装或检查 PATH。")) }
            let plan = try AgentLaunchPlan(tool: chosen, directory: cwd, executable: executable, action: action)
            let catalog = AgentSessionCatalog(target: target, transport: workspace.store.transport)
            let key = plan.record.map { target.identity + ":" + $0.id }
            if let key, let existing = workspace.sessions.first(where: { $0.agentRecordKey == key && ($0.connected || $0.connecting) }) {
                workspace.selectTerminal(existing); return true
            }
            let flag = cancellation
            _ = try await Task.detached { try catalog.prepare(plan, cancellation: flag) }.value
            try await validateSource()
            guard generation == request, !flag.isCancelled, source.connectionID == connection, source.connectionConfigurationValid() else { return false }
            let useTmux: Bool
            if case .docker = target { useTmux = true } else { useTmux = source.tmuxID != nil }
            let tmux = useTmux ? try await Task.detached { try catalog.createTmux(plan, cancellation: flag) }.value : nil
            guard !flag.isCancelled, source.connectionID == connection, source.connectionConfigurationValid() else {
                if let tmux { _ = try? await Task.detached { try TmuxService(transport: catalog.transport, host: target.host).kill(session: tmux) }.value }
                return false
            }
            workspace.launchAgent(catalog: catalog, plan: plan, key: key, tmux: tmux)
            return true
        } catch { if generation == request, !cancellation.isCancelled { failure = error.localizedDescription }; return false }
    }
    func focus(_ session: TerminalSession) { workspace?.selectTerminal(session) }
    func focusTmux(_ pane: TmuxPane) async -> Bool {
        guard let workspace, let target, !busy, source?.connectionID == connection, source?.connectionConfigurationValid() == true else { return false }
        let request = generation; let flag = cancellation
        busy = true; defer { if generation == request { busy = false } }
        do {
            try await validateSource()
            let service = TmuxService(transport: workspace.store.transport, host: target.host)
            let session = try await Task.detached {
                guard let current = try service.panes().first(where: { $0.id == pane.id }), current.sessionID == pane.sessionID,
                      current.command == pane.command, current.directory == pane.directory,
                      let session = try service.sessions().first(where: { $0.id == pane.sessionID }) else { throw WorkbenchError.message(L10n.text("原 tmux 会话已变化，请刷新列表。")) }
                return session
            }.value
            try await validateSource()
            guard generation == request, !flag.isCancelled else { return false }
            try await Task.detached { try service.select(pane: pane) }.value
            guard generation == request, !flag.isCancelled else { return false }
            if let existing = workspace.sessions.first(where: { $0.host?.id == target.host?.id && $0.tmuxID == session.id }) { workspace.selectTerminal(existing) }
            else { workspace.attachTmux(target.host, session: session) }
            return true
        } catch { if generation == request, !flag.isCancelled { failure = error.localizedDescription }; return false }
    }
}

struct AgentSessionsView: View {
    @StateObject private var model: AgentSessionsModel
    @ViewState private var showLaunchOptions = false
    @Environment(\.dismiss) private var dismiss
    init(workspace: Workspace) { _model = StateObject(wrappedValue: AgentSessionsModel(workspace: workspace)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.text("Agent 会话")).font(.title2); Spacer(); Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(model.target?.label ?? L10n.text("正在确认执行目标…")).font(.caption).textSelection(.enabled)
            Text(L10n.text("读取范围为上方设备及用户；终端内再次 SSH、切用户或自定义工具数据目录时，请改用实际连接或工具原生选择器。"))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("工具"), selection: $model.tool) { ForEach(CodingAgent.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Text(L10n.text("自动读取所选 Agent 在此设备用户下的全部项目会话；不按启动目录筛选，不发送聊天正文。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(L10n.text("搜索会话名称、路径或完整 ID"), text: $model.search)
                Button(L10n.text("刷新")) { Task { await model.refresh() } }.disabled(model.busy)
                if model.busy { Button(L10n.text("取消")) { model.stop() } }
            }
            if !model.running.isEmpty {
                Text(L10n.text("本窗口正在运行（点击切回，不重复启动）")).font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) { HStack { ForEach(model.running) { session in
                    Button(session.agentLaunch?.1.tool.title ?? session.title) { model.focus(session); dismiss() }
                } } }
            }
            if !model.tmuxPanes.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(model.tmuxPanes) { pane in
                    Button("tmux · " + pane.command + " · " + (pane.directory as NSString).lastPathComponent) {
                        Task { if await model.focusTmux(pane) { dismiss() } }
                    }.help(L10n.text("附着原 tmux 窗格，不重新启动 Agent；共享该会话的客户端也会看到窗格切换。"))
                } } }.frame(maxHeight: 32).disabled(model.busy)
            }
            Table(model.records, selection: $model.selection) {
                TableColumn(L10n.text("会话名称")) { Text($0.displayTitle).lineLimit(1).help($0.displayTitle) }.width(min: 150, ideal: 190)
                TableColumn(L10n.text("工作路径")) { Text($0.directory).lineLimit(1).truncationMode(.middle).help($0.directory) }.width(min: 180, ideal: 280)
                TableColumn(L10n.text("最后活跃时间")) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.activityDate.formatted(date: .numeric, time: .shortened))
                        if record.activitySource == "file" { Text(L10n.text("文件时间估计")).foregroundStyle(.secondary) }
                    }.font(.caption).help(record.activityDate.formatted())
                }.width(min: 130, ideal: 155)
                TableColumn(L10n.text("会话 ID")) { Text($0.sessionID).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).help($0.sessionID) }.width(270)
            }.alternatingRowBackgrounds(.disabled).frame(height: 280)
                .overlay {
                    if model.records.isEmpty {
                        VStack(spacing: 8) {
                            if model.busy { ProgressView(); Text(L10n.text("正在读取全部项目会话…")) }
                            else if model.failure != nil { Image(systemName: "exclamationmark.triangle"); Text(L10n.text("会话读取失败，请查看下方原因后重试。")) }
                            else if !model.search.isEmpty { Text(L10n.text("没有匹配的会话。")) }
                            else if model.listing == nil { Text(L10n.text("尚未取得列表，可点击刷新。")) }
                            else { Text(L10n.text("该 Agent 在此设备用户下没有可识别的会话。")) }
                        }.font(.callout).foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
            if model.busy, !model.records.isEmpty { HStack { ProgressView().controlSize(.small); Text(L10n.text("正在刷新，暂时显示上次列表…")) }.font(.caption) }
            if model.listing?.notices.contains("python3-unavailable") == true {
                Text(L10n.text("该设备没有 Python 3，历史列表不可用；仍可新建会话或打开工具原生选择器。")) .font(.caption).foregroundStyle(.orange)
            } else if model.listing?.notices.contains(where: { $0.hasSuffix(":root-missing") }) == true, model.records.isEmpty {
                Text(L10n.text("没有找到该用户的会话存储目录；容器、其他用户或自定义配置目录中的历史不会出现在这里。"))
                    .font(.caption).foregroundStyle(.orange)
            } else if let listing = model.listing, listing.truncated || !listing.notices.isEmpty {
                Text(L10n.text("列表可能不完整：部分记录无权限、格式未知或超过扫描范围。可使用工具原生选择器查看。"))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            DisclosureGroup(L10n.text("新建会话 / 打开目录（不影响上方列表）"), isExpanded: $showLaunchOptions) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L10n.text("启动目录"), text: $model.directory).font(.system(.caption, design: .monospaced))
                    HStack {
                        Button(L10n.text("在此目录新建会话")) { run(.newSession) }
                        Button(L10n.text("打开工具原生会话选择器")) { run(.picker) }
                        Button(L10n.text("在此目录新建终端")) { run(.shell) }
                    }.disabled(model.busy || model.listing == nil)
                }.padding(.top, 6)
            }
            Text(L10n.text("历史记录不代表进程已停止。恢复默认新开标签，不向当前 Agent 输入命令；不要同时恢复仍在其他终端运行的同一会话。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(L10n.text("\(model.records.count) 个会话 · 最后活跃时间倒序 · 全部项目")) .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("打开工作目录")) { if let selected = model.selected { model.directory = selected.directory; run(.shell) } }.disabled(model.selected == nil || model.busy)
                Button(L10n.text("在新标签恢复")) { if let selected = model.selected { run(.resume(selected)) } }.buttonStyle(.borderedProminent).disabled(model.selected == nil || model.busy)
            }
        }.padding(20).frame(width: 990).textFieldStyle(.roundedBorder)
            .task(id: model.tool) { await model.refresh() }.onDisappear { model.stop() }
    }
    private func run(_ action: AgentLaunchAction) { Task { if await model.launch(action) { dismiss() } } }
}
