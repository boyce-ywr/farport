import SwiftUI
import AppKit
import WorkbenchCore
import OpenSSHBackend

struct WorkspaceRoot: View {
    @ObservedObject var store: AppStore
    @StateObject private var workspace: Workspace
    @ViewState private var editingHost: HostProfile?
    @ViewState private var didPrepareQA = false
    @ViewState private var interactionFrames: [String: CGRect] = [:]
    @Environment(\.colorScheme) private var scheme
    init(store: AppStore) { self.store = store; _workspace = StateObject(wrappedValue: Workspace(store: store)) }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                topBar
                Divider()
                pageBar
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if workspace.showTransferTray && workspace.page != .transfers {
                    Divider(); TransferTray(store: store, expand: { workspace.page = .transfers })
                }
                Divider(); statusBar
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .coordinateSpace(name: "workspace-interactions")
        .onPreferenceChange(InteractionFrames.self) { interactionFrames = $0 }
        .focusedSceneObject(workspace)
        .sheet(item: $editingHost) { draft in
            HostEditor(profile: draft, store: store) { host in
                workspace.selectedHostID = host.id; editingHost = nil
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("知道了") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
        .task { await prepareQA() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Farport").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("栖远 · 连接远方，安放工作").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 44).padding(.bottom, 25)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("搜索主机", text: $workspace.hostSearch).textFieldStyle(.plain)
            }.padding(9).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 14)
            HStack {
                Text("我的主机").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { editingHost = HostProfile() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("添加主机")
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(groups, id: \.self) { group in
                        Text(group.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
                        ForEach(filteredHosts.filter { $0.group == group }) { host in hostRow(host) }
                    }
                    if filteredHosts.isEmpty {
                        Text(store.hosts.isEmpty ? "还没有主机\n添加一个连接，开始工作。" : "没有匹配的主机").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).padding(12)
                    }
                }.padding(.horizontal, 10)
            }
            Divider().padding(.horizontal, 16)
            VStack(spacing: 6) {
                Button { workspace.browsingLocalFiles = true; workspace.page = .files } label: {
                    HStack { Image(systemName: "internaldrive"); Text("此 Mac 的文件"); Spacer() }.padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { workspace.page = .transfers } label: {
                    HStack { Image(systemName: "arrow.left.arrow.right"); Text("传输中心"); Spacer(); if store.activeCount > 0 { Text("\(store.activeCount)").font(.caption).padding(.horizontal, 6).background(.teal.opacity(0.15), in: Capsule()) } }.padding(10)
                }.buttonStyle(.plain)
                Button { let panel = NSOpenPanel(); panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh"); if panel.runModal() == .OK, let url = panel.url { store.importSSHConfig(url) } } label: {
                    HStack { Image(systemName: "square.and.arrow.down"); Text("导入 SSH 配置"); Spacer() }.padding(10)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(10)
            HStack(spacing: 7) {
                Image(systemName: store.isTestWorkspace ? "testtube.2" : "lock.shield").foregroundStyle(.teal)
                Text(store.isTestWorkspace ? "隔离测试工作区" : "本地优先 · 安全连接").foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain)
            }.font(.system(size: 10)).padding(17)
        }.background(.ultraThinMaterial)
    }
    private var filteredHosts: [HostProfile] { store.hosts.filter { workspace.hostSearch.isEmpty || ($0.name + $0.address + $0.group).localizedCaseInsensitiveContains(workspace.hostSearch) } }
    private var groups: [String] { Array(Set(filteredHosts.map(\.group))).sorted() }
    private var displayHost: HostProfile? { workspace.page == .terminal ? (workspace.selectedTerminal?.host ?? workspace.host) : workspace.host }
    private func hostRow(_ host: HostProfile) -> some View {
        let selected = workspace.selectedHostID == host.id
        return HStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 16)).foregroundStyle(host.color == "blue" ? .blue : .teal)
                .frame(width: 34, height: 36).background((host.color == "blue" ? Color.blue : Color.teal).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(host.name).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                Text(verbatim: "\(host.address):\(host.port)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected { RoundedRectangle(cornerRadius: 2).fill(.teal).frame(width: 3, height: 22) }
        }.padding(8).background(selected ? Color.teal.opacity(scheme == .dark ? 0.16 : 0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle()).onTapGesture { workspace.browsingLocalFiles = false; workspace.selectedHostID = host.id }
            .onTapGesture(count: 2) { workspace.connectPreferred(host) }
            .contextMenu {
                Button("连接普通终端") { workspace.connect(host) }
                Button("管理 tmux") { workspace.selectedHostID = host.id; workspace.page = .tmux }
                Button("浏览文件") { workspace.browsingLocalFiles = false; workspace.selectedHostID = host.id; workspace.page = .files }
                Divider()
                Button("编辑主机") { editingHost = host }
                Button("清除此主机保存的凭据") { store.forgetCredentials(host) }
                Button("移除主机", role: .destructive) {
                    if confirm("移除“\(host.name)”？", "仅移除本地配置，不删除远端文件或 tmux 会话。") { store.removeHost(host) }
                }
            }
    }
    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(workspace.page == .files && (workspace.browsingLocalFiles || workspace.host == nil) ? "此 Mac · 本地文件" : (displayHost?.name ?? "你的远程工作空间")).font(.system(size: 18, weight: .semibold))
                    if workspace.host != nil && !(workspace.page == .files && workspace.browsingLocalFiles) { Text("SSH").font(.system(size: 9, weight: .bold, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 3).foregroundStyle(.teal).background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 4)) }
                }
                Text(workspace.page == .files && (workspace.browsingLocalFiles || workspace.host == nil) ? "本机与 SSH 主机之间自由复制文件 / 文件夹" : (displayHost?.subtitle ?? "终端、持久会话与远程文件，一处掌控。")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { workspace.showTransferTray.toggle() } label: { Image(systemName: "tray.and.arrow.down") }.help("显示传输队列")
            Button { if let host = workspace.host { workspace.connect(host, split: true) } } label: { Image(systemName: "rectangle.split.2x1") }.help("新建分屏终端").disabled(workspace.host == nil)
            Button { if let host = workspace.host { workspace.connectPreferred(host) } else { editingHost = HostProfile() } } label: {
                Label(workspace.host == nil ? "添加主机" : "连接主机", systemImage: "plus")
            }.buttonStyle(.borderedProminent).controlSize(.large)
        }.buttonStyle(.borderless).padding(.horizontal, 26).padding(.top, 23).padding(.bottom, 18)
    }
    private var pageBar: some View {
        HStack(spacing: 24) {
            ForEach(WorkspacePage.allCases, id: \.self) { page in
                Button { workspace.page = page } label: {
                    VStack(spacing: 12) {
                        Label(page.rawValue, systemImage: page.symbol).font(.system(size: 12, weight: workspace.page == page ? .semibold : .regular)).foregroundStyle(workspace.page == page ? Color.teal : .secondary)
                        Capsule().fill(workspace.page == page ? Color.teal : .clear).frame(height: 2)
                    }.padding(.horizontal, 12).padding(.top, 14).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).interactionFrame("page.\(page.rawValue)")
            }
            Spacer()
            Text("⌘ 1–5 切换工作区").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 4)
        }.padding(.horizontal, 26)
    }
    @ViewBuilder private var content: some View {
        switch workspace.page {
        case .terminal: TerminalWorkspace(workspace: workspace, store: store, addHost: { editingHost = HostProfile() })
        case .tmux:
            if let host = workspace.host { TmuxWorkspace(host: host, store: store, workspace: workspace).id(host) }
            else { EmptyWorkspace(symbol: "square.stack.3d.up", title: "把远端工作留在远端", detail: "先添加主机，再创建和管理 tmux 会话。", action: "添加主机") { editingHost = HostProfile() } }
        case .files:
            let fileHost = workspace.browsingLocalFiles ? nil : workspace.host
            FileWorkspace(host: fileHost, store: store).id(fileHost)
        case .transfers: TransferWorkspace(store: store)
        case .tunnels:
            if let host = workspace.host { TunnelWorkspace(host: host, store: store).id(host) }
            else { EmptyWorkspace(symbol: "point.3.connected.trianglepath.dotted", title: "安全访问远端服务", detail: "选择主机后创建 SSH 隧道。", action: "添加主机") { editingHost = HostProfile() } }
        }
    }
    private var statusBar: some View {
        HStack(spacing: 15) {
            Label("OpenSSH", systemImage: "lock.shield").foregroundStyle(.secondary)
            Text("UTF-8").foregroundStyle(.tertiary)
            Spacer()
            if let terminal = workspace.selectedTerminal, workspace.page == .terminal {
                TerminalStatus(session: terminal, showReconnect: false)
            }
            Text("\(store.hosts.count) 台主机 · \(workspace.sessions.count) 个终端").foregroundStyle(.secondary)
        }.font(.system(size: 10)).padding(.horizontal, 20).frame(height: 30)
    }
    private func prepareQA() async {
        guard !didPrepareQA, store.isTestWorkspace, let output = ProcessInfo.processInfo.environment["SWB_QA_OUTPUT"] else { return }
        didPrepareQA = true
        let screen = ProcessInfo.processInfo.environment["SWB_QA_SCREEN"] ?? "terminal"
        if ProcessInfo.processInfo.environment["SWB_QA_INTERACTIONS"] == "1" {
            await verifyTabInteractions()
        }
        if let appearance = ProcessInfo.processInfo.environment["SWB_QA_APPEARANCE"] { store.appearance = appearance }
        if let host = workspace.host {
            if screen == "terminal" || screen == "split" || screen == "tmux-terminal" {
                if screen == "tmux-terminal" {
                    let service = TmuxService(transport: store.transport, host: host)
                    if let sessions = try? await Task.detached(operation: { try service.sessions() }).value,
                       let session = sessions.first(where: { $0.name == "development" }) {
                        workspace.connect(host, tmux: session.id, sessionName: session.name)
                    }
                } else {
                    workspace.connect(host)
                }
                for _ in 0..<100 {
                    if workspace.selectedTerminal?.connected == true { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                workspace.selectedTerminal?.terminal.send(txt: "clear; printf '\\033[1;36m栖远 Farport · 真实 Linux 测试环境\\033[0m\\n\\n'; uname -sm; printf '\\n'; pwd; ls -lah workspace; printf '\\n'; tmux list-sessions\n")
                if screen == "split", let otherHost = store.hosts.first(where: { $0.id != host.id }) {
                    workspace.connect(otherHost, split: true)
                }
            } else if screen == "files" || screen == "local-files" { workspace.browsingLocalFiles = screen == "local-files"; workspace.page = .files }
            else if screen == "tmux" { workspace.page = .tmux }
            else if screen == "transfers" { workspace.page = .transfers }
            else if screen == "host-editor" { editingHost = host }
        }
        if let widthText = ProcessInfo.processInfo.environment["SWB_QA_WIDTH"], let width = Double(widthText),
           let heightText = ProcessInfo.processInfo.environment["SWB_QA_HEIGHT"], let height = Double(heightText),
           let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
            window.setContentSize(NSSize(width: max(980, width), height: max(640, height)))
        }
        try? await Task.sleep(for: .seconds(ProcessInfo.processInfo.environment["SWB_QA_BATCH_COPY"] == "1" ? 35 : (ProcessInfo.processInfo.environment["SWB_QA_FILE_NAVIGATION"] == "1" ? 15 : 5)))
        let expected: WorkspacePage = screen == "files" || screen == "local-files" ? .files : (screen == "tmux" ? .tmux : (screen == "transfers" ? .transfers : .terminal))
        guard workspace.page == expected else {
            fputs("截图验收失败：请求页面与实际工作区不一致。\n", stderr)
            exit(1)
        }
        if expected == .terminal, screen != "host-editor", workspace.selectedTerminal?.connected != true {
            fputs("截图验收失败：SSH 终端尚未连接。\n", stderr)
            exit(1)
        }
        let parentWindow = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        if let window = screen == "host-editor" ? (parentWindow?.sheets.first ?? parentWindow) : parentWindow, let view = window.contentView?.superview {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(300))
            window.displayIfNeeded()
            let screenshot = try? ProcessRunner.run(executable: "/usr/sbin/screencapture", arguments: ["-x", "-l", String(window.windowNumber), output], timeout: 5)
            if screenshot?.status != 0, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: image)
                if let context = NSGraphicsContext(bitmapImageRep: image)?.cgContext {
                    context.saveGState()
                    context.scaleBy(x: CGFloat(image.pixelsWide) / view.bounds.width, y: CGFloat(image.pixelsHigh) / view.bounds.height)
                    context.setBlendMode(.destinationOver)
                    for session in workspace.sessions where session.terminal.window === window && !session.terminal.isHiddenOrHasHiddenAncestor {
                        let terminal = session.terminal
                        context.setFillColor(terminal.nativeBackgroundColor.cgColor)
                        context.fill(terminal.convert(terminal.bounds, to: view))
                    }
                    context.restoreGState()
                }
                if let data = image.representation(using: .png, properties: [:]) {
                    do { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
                    catch { fputs("截图保存失败：\(error.localizedDescription)\n", stderr) }
                }
            }
            var metadata: [String: Any] = ["requestedScreen": screen, "actualPage": workspace.page.rawValue,
                                          "capture": screenshot?.status == 0 ? "windowserver" : "view-cache-with-layer-background",
                                          "bundleIdentifier": Bundle.main.bundleIdentifier ?? "development",
                                          "appearance": store.appearance, "width": view.bounds.width, "height": view.bounds.height]
            if let session = workspace.selectedTerminal {
                metadata["terminalState"] = session.state; metadata["font"] = session.terminal.font.fontName
                metadata["fontSize"] = session.terminal.font.pointSize
            }
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: output + ".json")) }
        } else {
            fputs("截图验收失败：应用没有可见窗口。\n", stderr)
            exit(1)
        }
        if ProcessInfo.processInfo.environment["SWB_QA_EXIT"] == "1" {
            if editingHost != nil { editingHost = nil; try? await Task.sleep(for: .milliseconds(300)) }
            NSApp.terminate(nil)
        }
    }
    @MainActor private func verifyTabInteractions() async {
        guard let host = workspace.host else { exit(1) }
        workspace.connect(host)
        guard let firstID = workspace.selectedTerminalID else { exit(1) }
        workspace.connect(host, split: true)
        guard let secondID = workspace.splitTerminalID else { exit(1) }
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let secondFrame = interactionFrames["terminal.\(secondID.uuidString)"] else { exit(1) }
        await clickInterface(secondFrame, window: window)
        guard workspace.splitTerminalID == secondID, workspace.layout.primary == firstID, workspace.selectedTerminalID == secondID else {
            fputs("FAIL · 点击分屏终端标签后布局被清空\n", stderr); exit(1)
        }
        guard let firstFrame = interactionFrames["terminal.\(firstID.uuidString)"] else { exit(1) }
        await clickInterface(firstFrame, window: window, xFraction: 0.1)
        guard workspace.splitTerminalID == secondID, workspace.layout.primary == firstID, workspace.selectedTerminalID == firstID else { fputs("FAIL · 切回原终端时分屏丢失：primary=\(workspace.layout.primary == firstID) secondary=\(workspace.splitTerminalID == secondID) focused=\(workspace.selectedTerminalID == firstID)\n", stderr); exit(1) }
        guard let filesFrame = interactionFrames["page.文件"] else { exit(1) }
        await clickInterface(filesFrame, window: window, xFraction: 0.05, yFraction: 0.5)
        guard workspace.page == .files else { fputs("FAIL · 工作区标签空白区域不可点击\n", stderr); exit(1) }
        guard let terminalFrame = interactionFrames["page.终端"] else { exit(1) }
        await clickInterface(terminalFrame, window: window, xFraction: 0.95, yFraction: 0.5)
        guard workspace.page == .terminal, workspace.splitTerminalID != nil else { fputs("FAIL · 切换工作区后分屏丢失\n", stderr); exit(1) }
        print("PASS · 分屏标签切换与标签空白点击区域")
    }
}

struct EmptyWorkspace: View {
    let symbol: String; let title: String; let detail: String; let action: String; let perform: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.teal).frame(width: 86, height: 86).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.system(size: 23, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            Button(action, action: perform).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
    }
}

func confirm(_ title: String, _ detail: String) -> Bool {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
    alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
}
