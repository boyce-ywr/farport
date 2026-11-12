import SwiftUI
import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class TmuxModel: ObservableObject {
    @Published var sessions: [TmuxSession] = []
    @Published var panes: [TmuxPane] = []
    @Published var busy = false
    @Published var errorMessage: String?
    /// nil 表示尚未检测；false 表示目标主机没有 tmux，此时不报错，只在会话页注明。
    @Published var installed: Bool?
    let service: TmuxService
    private let detector: MultiplexerService
    init(host: HostProfile?, store: AppStore) {
        service = TmuxService(transport: store.transport, host: host)
        detector = MultiplexerService(kind: .tmux, transport: store.transport, host: host)
    }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let service = service, detector = detector, known = installed == true
            let result = try await Task.detached { () -> ([TmuxSession], [TmuxPane])? in
                if !known, try detector.availability() == .missing { return nil }
                let sessions = try service.sessions(); return (sessions, sessions.isEmpty ? [] : try service.panes())
            }.value
            installed = result != nil
            sessions = result?.0 ?? []; panes = result?.1 ?? []; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func perform(_ operation: @escaping @Sendable (TmuxService) throws -> Void) {
        guard !busy else { return }; busy = true
        let service = service
        Task {
            do { try await Task.detached { try operation(service) }.value; busy = false; await refresh() }
            catch { busy = false; errorMessage = error.localizedDescription }
        }
    }
}

/// Zellij 或 herdr 的会话列表与操作。
@MainActor
final class MultiplexerModel: ObservableObject {
    @Published var availability: MultiplexerService.Availability?
    @Published var sessions: [MultiplexerSession] = []
    @Published var panes: [MultiplexerPane] = []
    @Published var busy = false
    @Published var errorMessage: String?
    let service: MultiplexerService
    init(kind: MultiplexerKind, host: HostProfile?, store: AppStore) { service = MultiplexerService(kind: kind, transport: store.transport, host: host) }
    var usable: Bool { if case .available = availability { return true }; return false }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let service = service, known = usable
            let result = try await Task.detached { () -> (MultiplexerService.Availability, [MultiplexerSession], [MultiplexerPane]) in
                let availability = known ? .available("") : try service.availability()
                guard case .available = availability else { return (availability, [], []) }
                let sessions = try service.sessions()
                return (availability, sessions, try service.panes(of: sessions))
            }.value
            if !known { availability = result.0 }
            sessions = result.1; panes = result.2; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func perform(_ operation: @escaping @Sendable (MultiplexerService) throws -> Void) {
        guard !busy else { return }; busy = true
        let service = service
        Task {
            do { try await Task.detached { try operation(service) }.value; busy = false; await refresh() }
            catch { busy = false; errorMessage = error.localizedDescription }
        }
    }
}

struct TmuxWorkspace: View {
    let host: HostProfile?
    @ObservedObject var store: AppStore
    @ObservedObject var workspace: Workspace
    @StateObject private var model: TmuxModel
    @StateObject private var zellij: MultiplexerModel
    @StateObject private var herdr: MultiplexerModel
    init(host: HostProfile?, store: AppStore, workspace: Workspace) {
        self.host = host; self.store = store; self.workspace = workspace
        _model = StateObject(wrappedValue: TmuxModel(host: host, store: store))
        _zellij = StateObject(wrappedValue: MultiplexerModel(kind: .zellij, host: host, store: store))
        _herdr = StateObject(wrappedValue: MultiplexerModel(kind: .herdr, host: host, store: store))
    }
    private var others: [MultiplexerModel] { [zellij, herdr] }
    private var busy: Bool { model.busy || others.contains(where: \.busy) }
    private var missing: [String] {
        (model.installed == false ? ["tmux"] : []) + others.filter { $0.availability == .missing }.map(\.service.kind.title)
    }
    private var totalSessions: Int { model.sessions.count + others.reduce(0) { $0 + $1.sessions.filter(\.running).count } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("让工作持续在线")).font(.system(size: 23, weight: .semibold))
                    Text(host == nil ? L10n.text("管理此 Mac 的 tmux、Zellij、herdr 会话，会话不会随终端标签关闭。") : L10n.text("管理远端 tmux、Zellij、herdr 会话，会话与终端连接各自独立。")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button { Task { await refreshAll() } } label: { Image(systemName: "arrow.clockwise") }.help(L10n.text("刷新远端会话"))
                Menu {
                    if model.installed != false { Button("tmux") { createTmux() } }
                    ForEach(others.filter(\.usable), id: \.service.kind) { other in Button(other.service.kind.title) { create(other) } }
                } label: { Label(L10n.text("新建会话"), systemImage: "plus") }.menuStyle(.borderedButton).fixedSize()
            }
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(L10n.text("Codex 宠物需在普通终端运行，Codex 暂不支持 tmux、Zellij 内显示。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("打开普通终端")) { if let host { workspace.connect(host) } else { workspace.connectLocal() } }
                    .font(.caption)
            }
            HStack(spacing: 14) {
                metric(L10n.text("持久会话"), value: totalSessions, symbol: "square.stack.3d.up", caption: L10n.text("保留工作现场"))
                metric(L10n.text("终端窗格"), value: model.panes.count + others.reduce(0) { $0 + $1.panes.count }, symbol: "rectangle.split.2x1", caption: L10n.text("查看进程与工作目录"))
                metric(L10n.text("已附着客户端"), value: model.sessions.reduce(0) { $0 + $1.attached }, symbol: "link", caption: L10n.text("tmux 返回的实时状态"))
            }
            if let error = model.errorMessage { ErrorBanner(message: error) { model.errorMessage = nil } }
            ForEach(others.filter { $0.errorMessage != nil && $0.errorMessage != model.errorMessage }, id: \.service.kind) { other in
                ErrorBanner(message: other.service.kind.title + "：" + (other.errorMessage ?? "")) { other.errorMessage = nil }
            }
            if totalSessions == 0 && others.allSatisfy({ $0.sessions.isEmpty }) && !busy {
                EmptyWorkspace(symbol: "square.stack.3d.up", title: model.errorMessage == nil ? L10n.text("还没有会话") : L10n.text("暂时无法读取 tmux"), detail: L10n.text("没有 tmux、Zellij 或 herdr 时仍可使用普通终端。\n不会擅自安装或修改配置。"), action: L10n.text("打开普通终端")) { if let host { workspace.connect(host) } else { workspace.connectLocal() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !model.sessions.isEmpty {
                            section("tmux", version: nil) {
                                ForEach(model.sessions) { session in sessionCard(session) }
                            }
                        }
                        ForEach(others.filter { !$0.sessions.isEmpty }, id: \.service.kind) { other in otherSection(other) }
                    }
                }
            }
            ForEach(others.filter { if case .outdated = $0.availability { return true }; return false }, id: \.service.kind) { other in
                if case .outdated(let version) = other.availability {
                    Label(L10n.text("\(other.service.kind.title) 版本过低（\(version)），需要 \(other.service.kind.minimumVersion.0).\(other.service.kind.minimumVersion.1) 或更高版本；已停用相关操作。"), systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            if !missing.isEmpty { Text(L10n.text("未检测到：\(missing.joined(separator: "、"))")).font(.system(size: 11)).foregroundStyle(.tertiary) }
            HStack(spacing: 8) { Image(systemName: "info.circle"); Text(L10n.text("关闭终端标签只会断开连接。“结束会话”才会终止会话中的任务。")) }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(26)
            .task { await refreshAll(); while !Task.isCancelled { try? await Task.sleep(for: .seconds(8)); if !Task.isCancelled { await refreshAll() } } }
    }
    private func refreshAll() async {
        async let tmux: Void = model.refresh()
        async let zellijRefresh: Void = zellij.refresh()
        async let herdrRefresh: Void = herdr.refresh()
        _ = await (tmux, zellijRefresh, herdrRefresh)
    }
    private func createTmux() {
        if let name = promptText(L10n.text("新建 tmux 会话"), detail: L10n.text("会话在当前机器创建，关闭标签不会结束它。"), initial: "work") { model.perform { try $0.create(name: name) } }
    }
    private func create(_ other: MultiplexerModel) {
        let kind = other.service.kind
        let detail = other.service.createsInBackground ? L10n.text("会话在当前机器创建，关闭标签不会结束它。") : L10n.text("\(kind.title) 会在新终端标签中创建并进入会话，关闭标签不会结束它。")
        guard let name = promptText(L10n.text("新建 \(kind.title) 会话"), detail: detail, initial: "work") else { return }
        if other.service.createsInBackground { other.perform { _ = try $0.createDetached(name: name) }; return }
        do {
            try kind.validateSessionName(name)
            guard !other.sessions.contains(where: { $0.name == name }) else { throw WorkbenchError.message(L10n.text("已存在同名会话，请换一个名称。")) }
            workspace.attachMultiplexer(host, attachment: MultiplexerAttachment(kind: kind, session: name, create: true))
        } catch { other.errorMessage = error.localizedDescription }
    }
    private func section<Content: View>(_ title: String, version: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let version { Text(version).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], alignment: .leading, spacing: 16) { content() }
        }
    }
    @ViewBuilder private func otherSection(_ other: MultiplexerModel) -> some View {
        let version: String? = { if case .available(let text) = other.availability { return text }; return nil }()
        let running = other.sessions.filter(\.running), exited = other.sessions.filter { !$0.running }
        section(other.service.kind.title, version: version) {
            ForEach(running) { session in otherCard(session, model: other) }
        }
        if !exited.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("已退出的 \(other.service.kind.title) 会话")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(exited) { session in
                    HStack {
                        Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                        Text(session.name).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button(L10n.text("删除…"), role: .destructive) {
                            if confirm(L10n.text("删除已退出的“\(session.name)”？"), L10n.text("只删除 \(other.service.kind.title) 保存的会话记录，不会恢复或重新运行其中的命令。")) { other.perform { try $0.kill(session: session) } }
                        }.disabled(other.busy)
                    }.padding(.horizontal, 12).padding(.vertical, 7).background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                }
                Text(L10n.text("Farport 不提供“恢复”：\(other.service.kind.title) 恢复已退出会话会重新运行记录的命令，而不是继续原来的进程。")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
    private func otherCard(_ session: MultiplexerSession, model other: MultiplexerModel) -> some View {
        let kind = other.service.kind
        let panes = other.panes.filter { $0.session == session.name }
        return VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").font(.title3).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) { Text(session.name).font(.system(size: 15, weight: .semibold)); Text(L10n.text("\(kind.title) · \(panes.count) 个窗格")).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    Button(L10n.text("重命名会话")) { if let name = promptText(L10n.text("重命名会话"), initial: session.name) { other.perform { try $0.rename(session: session.name, to: name) } } }
                        .disabled(!kind.canRename).help(kind.canRename ? "" : L10n.text("herdr 不支持重命名会话。"))
                    Divider()
                    Button(L10n.text("结束会话…"), role: .destructive) { if confirm(L10n.text("结束“\(session.name)”？"), L10n.text("这会终止此 \(kind.title) 会话中的全部窗格和正在运行的任务（包括 Agent），并删除会话记录，无法撤销。")) { other.perform { try $0.kill(session: session) } } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            Divider()
            ForEach(panes) { pane in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2).fill(pane.focused ? Color.teal : .secondary.opacity(0.3)).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(pane.group).fontWeight(.medium)
                            Text("\(pane.id) · \(pane.command)").foregroundStyle(.secondary).lineLimit(1)
                            if let agent = pane.agent { Text([agent, pane.agentStatus].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.teal) }
                        }.font(.system(size: 11, design: .monospaced))
                        Text(pane.directory).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                }
            }
            HStack { Spacer(); Button(L10n.text("进入会话")) { workspace.attachMultiplexer(host, attachment: MultiplexerAttachment(kind: kind, session: session.name)) }.buttonStyle(.bordered).tint(.teal) }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.quaternary.opacity(0.65)))
    }
    private func metric(_ title: String, value: Int, symbol: String, caption: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); Text("\(value)").font(.system(size: 29, weight: .semibold, design: .rounded)); Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary) }
            Spacer(); Image(systemName: symbol).foregroundStyle(.teal).padding(8).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
    }
    private func sessionCard(_ session: TmuxSession) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").font(.title3).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) { Text(session.name).font(.system(size: 15, weight: .semibold)); Text(L10n.text("\(session.windows) 个窗口 · \(session.attached) 个客户端")).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    Button(L10n.text("新建窗口")) { model.perform { try $0.createWindow(session: session.id) } }
                    Button(L10n.text("重命名会话")) { if let name = promptText(L10n.text("重命名会话"), initial: session.name) { model.perform { try $0.rename(session: session.id, name: name) } } }
                    Divider()
                    Button(L10n.text("结束会话…"), role: .destructive) { if confirm(L10n.text("结束“\(session.name)”？"), L10n.text("这会终止此远端会话中的全部窗口、窗格和正在运行的任务，无法撤销。")) { model.perform { try $0.kill(session: session.id) } } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            Divider()
            ForEach(model.panes.filter { $0.sessionID == session.id }) { pane in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2).fill(pane.active ? Color.teal : .secondary.opacity(0.3)).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(pane.windowName).fontWeight(.medium); Text("\(pane.id) · \(pane.command)").foregroundStyle(.secondary) }.font(.system(size: 11, design: .monospaced))
                        Text(pane.directory).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Button { model.perform { try $0.select(pane: pane) }; workspace.attachTmux(host, session: session) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help(L10n.text("进入此窗格"))
                }.contextMenu { Button(L10n.text("横向分割窗格")) { model.perform { try $0.split(pane: pane.id) } } }
            }
            HStack { Text(session.created, style: .date).font(.system(size: 10)).foregroundStyle(.tertiary); Spacer(); Button(L10n.text("进入会话")) { workspace.attachTmux(host, session: session) }.buttonStyle(.bordered).tint(.teal) }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.quaternary.opacity(0.65)))
    }
}

func promptText(_ title: String, detail: String = "", initial: String = "") -> String? {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
    let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 360, height: 25); alert.accessoryView = field; alert.window.initialFirstResponder = field
    alert.addButton(withTitle: L10n.text("确定")); alert.addButton(withTitle: L10n.text("取消"))
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 9) { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); Text(message).font(.system(size: 11)).textSelection(.enabled); Spacer(); Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain) }
            .padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
