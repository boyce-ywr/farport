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
            if !workspace.sidebarCollapsed { sidebar.frame(width: 206); Divider() }
            VStack(spacing: 0) {
                pageBar
                Divider()
                if [.terminal, .files].contains(workspace.page), !workspace.sessions.isEmpty { SessionTabs(workspace: workspace); Divider() }
                if let draft = workspace.attachmentDraft {
                    CompactAttachmentNotice(draft: draft) { workspace.attachmentDraft = nil }
                }
                if let job = store.pendingConflict { TransferConflictBanner(job: job, store: store); Divider() }
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
        .onChange(of: store.automaticallyReconnectSSH) { _, enabled in workspace.sessions.forEach { $0.setAutomaticReconnect(enabled) } }
        .overlay(alignment: .topTrailing) {
            if let notice = store.taskNotice {
                HStack(alignment: .top) {
                    Label(notice, systemImage: "bell.badge").font(.caption).lineLimit(3)
                    Button { store.taskNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help(L10n.text("关闭提醒"))
                }.padding(12).frame(maxWidth: 370).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).shadow(radius: 4).padding(.top, 48).padding(.trailing, 14)
            }
        }
        .sheet(isPresented: $workspace.showCommandSnippets) { CommandSnippetsView(workspace: workspace, store: store) }
        .sheet(item: $workspace.screenSharingHost) { host in ScreenSharingView(host: host, store: store) }
        .sheet(item: $workspace.webServiceHost) { host in WebServicesView(host: host, store: store) }
        .background(WindowTitlebar().frame(width: 0, height: 0))
        .sheet(item: $editingHost) { draft in
            HostEditor(profile: draft, store: store) { host in
                workspace.selectedHostID = host.id; editingHost = nil
            }
        }
        .alert(L10n.text("操作未完成"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button(L10n.text("知道了")) { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
        .task { await prepareQA() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Farport").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L10n.text("栖远 · 连接远方，安放工作")).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 16)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(L10n.text("搜索主机"), text: $workspace.hostSearch).textFieldStyle(.plain)
            }.padding(9).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 14)
            Button { workspace.openLocalTerminal() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").font(.system(size: 17)).foregroundStyle(.teal)
                        .frame(width: 34, height: 36).background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("本机终端")).font(.system(size: 12, weight: .semibold))
                        Text(L10n.text("此 Mac · 登录 Shell")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if showingLocalTerminal { RoundedRectangle(cornerRadius: 2).fill(.teal).frame(width: 3, height: 22) }
                }.padding(8).frame(maxWidth: .infinity).contentShape(Rectangle())
                    .background(showingLocalTerminal ? Color.teal.opacity(scheme == .dark ? 0.16 : 0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 14).help(L10n.text("在 Farport 中打开本机登录 Shell"))
                .interactionFrame("local-terminal")
                .contextMenu {
                    Button(L10n.text("新建本机终端")) { workspace.connectLocal() }
                    Button(L10n.text("添加本机分屏")) { workspace.connectLocal(split: true) }
                }
            HStack {
                Text(L10n.text("我的主机")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { editingHost = HostProfile() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help(L10n.text("添加主机"))
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(groups, id: \.self) { group in
                        Text(group.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
                        ForEach(filteredHosts.filter { $0.group == group }) { host in hostRow(host) }
                    }
                    if filteredHosts.isEmpty {
                        Text(store.hosts.isEmpty ? L10n.text("还没有主机\n添加一个连接，开始工作。") : L10n.text("没有匹配的主机")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).padding(12)
                    }
                }.padding(.horizontal, 10)
            }
            Divider().padding(.horizontal, 16)
            VStack(spacing: 6) {
                Button { workspace.browseFiles(.local) } label: {
                    HStack { Image(systemName: "internaldrive"); Text(L10n.text("此 Mac 的文件")); Spacer() }.padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { workspace.page = .transfers } label: {
                    HStack { Image(systemName: "arrow.left.arrow.right"); Text(L10n.text("传输中心")); Spacer(); if store.activeCount > 0 { Text("\(store.activeCount)").font(.caption).padding(.horizontal, 6).background(.teal.opacity(0.15), in: Capsule()) } }.padding(10)
                }.buttonStyle(.plain)
                Button { let panel = NSOpenPanel(); panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh"); if panel.runModal() == .OK, let url = panel.url { store.importSSHConfig(url) } } label: {
                    HStack { Image(systemName: "square.and.arrow.down"); Text(L10n.text("导入 SSH 配置")); Spacer() }.padding(10)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(10)
            HStack(spacing: 7) {
                Image(systemName: store.isTestWorkspace ? "testtube.2" : "lock.shield").foregroundStyle(.teal)
                Text(store.isTestWorkspace ? L10n.text("隔离测试工作区") : L10n.text("本地优先 · 安全连接")).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain)
            }.font(.system(size: 10)).padding(17)
        }.background(.ultraThinMaterial)
    }
    private var filteredHosts: [HostProfile] { store.hosts.filter { workspace.hostSearch.isEmpty || ($0.name + $0.address + $0.group).localizedCaseInsensitiveContains(workspace.hostSearch) } }
    private var groups: [String] { Array(Set(filteredHosts.map(\.group))).sorted() }
    private var showingLocalTerminal: Bool { workspace.page == .terminal && (workspace.selectedTerminal?.isLocal ?? (workspace.host == nil)) }
    private var displayHost: HostProfile? { workspace.page == .files ? workspace.fileHost : (workspace.page == .terminal ? (workspace.selectedTerminal?.host ?? workspace.host) : workspace.host) }
    private func hostRow(_ host: HostProfile) -> some View {
        let selected = (workspace.page == .files ? workspace.fileHost?.id : workspace.selectedHostID) == host.id
        return HStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 16)).foregroundStyle(host.markColor)
                .frame(width: 34, height: 36).background(host.markColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(host.name).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                Text(verbatim: "\(host.address):\(host.port)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected { RoundedRectangle(cornerRadius: 2).fill(host.markColor).frame(width: 3, height: 22) }
        }.padding(8).background(selected ? host.markColor.opacity(scheme == .dark ? 0.16 : 0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle()).onTapGesture { workspace.selectHost(host) }
            .onTapGesture(count: 2) { workspace.connectPreferred(host) }
            .contextMenu {
                Button(L10n.text("连接普通终端")) { workspace.connect(host) }
                Button(L10n.text("管理 tmux")) { workspace.selectedHostID = host.id; workspace.page = .tmux }
                Button(L10n.text("浏览文件")) { workspace.browseFiles(.host(host.id)) }
                Button(L10n.text("主机监控")) { workspace.selectedHostID = host.id; workspace.page = .monitor }
                Button(L10n.text("打开远程 Mac 桌面…")) { workspace.screenSharingHost = host }
                Divider()
                Button(L10n.text("编辑主机")) { editingHost = host }
                Button(L10n.text("清除此主机保存的凭据")) { store.forgetCredentials(host) }
                Button(L10n.text("移除主机"), role: .destructive) {
                    if confirm(L10n.text("移除“\(host.name)”？"), L10n.text("仅移除本地配置，不删除远端文件或 tmux 会话。")) { store.removeHost(host) }
                }
            }
    }
    private var pageBar: some View {
        HStack(spacing: 6) {
            Button { workspace.toggleSidebar() } label: { Image(systemName: "sidebar.left").frame(width: 30, height: 32) }
                .help(L10n.text("展开 / 折叠主机侧栏 · ⌘⌥S")).interactionFrame("workspace.sidebar")
            ForEach(WorkspacePage.allCases, id: \.self) { page in
                Button { workspace.page = page } label: {
                    Label(page.title, systemImage: page.symbol).font(.system(size: 11, weight: workspace.page == page ? .semibold : .regular))
                        .foregroundStyle(workspace.page == page ? Color.teal : .secondary).padding(.horizontal, 10).frame(height: 32)
                        .background(workspace.page == page ? Color.teal.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                }.buttonStyle(.plain).interactionFrame("page.\(page.rawValue)")
            }
            Spacer()
            Menu {
                if workspace.page == .files { Button(L10n.text("此 Mac 的文件")) { workspace.browseFiles(.local) } }
                else { Button(L10n.text("新建本机终端")) { workspace.connectLocal() } }
                ForEach(store.hosts) { host in Button(host.name) { if workspace.page == .files { workspace.browseFiles(.host(host.id)) } else { workspace.connectPreferred(host) } } }
                Divider(); Button(L10n.text("添加 SSH 主机…")) { editingHost = HostProfile() }
            } label: { Label(displayHost?.name ?? L10n.text("此 Mac"), systemImage: "server.rack").lineLimit(1) }.menuStyle(.borderlessButton).frame(maxWidth: 160)
            WorkspaceToolsMenu(workspace: workspace, store: store)
            Button { workspace.showTransferTray.toggle() } label: { Image(systemName: "tray.and.arrow.down").frame(width: 26, height: 32) }.help(L10n.text("传输队列"))
            if workspace.page == .terminal {
                Button { workspace.showTerminalSearch.toggle() } label: { Image(systemName: "magnifyingglass").frame(width: 26, height: 32) }.help(L10n.text("查找终端内容 · ⌘F"))
                Button { workspace.chooseAttachments() } label: { Image(systemName: "paperclip").frame(width: 26, height: 32) }.help(L10n.text("发送附件")).disabled(workspace.selectedTerminal?.connected != true)
            }
        }.font(.system(size: 11)).buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 4)
    }
    @ViewBuilder private var content: some View {
        switch workspace.page {
        case .terminal: TerminalWorkspace(workspace: workspace, store: store, addHost: { editingHost = HostProfile() })
        case .tmux:
            TmuxWorkspace(host: workspace.host, store: store, workspace: workspace).id(workspace.host)
        case .files:
            FilePaneWorkspace(workspace: workspace, store: store)
        case .transfers: TransferWorkspace(store: store)
        case .monitor: HostMonitorWorkspace(workspace: workspace, store: store).id(workspace.host?.connectionKey ?? "local")
        case .tunnels:
            if let host = workspace.host { TunnelWorkspace(host: host, store: store).id(host) }
            else { EmptyWorkspace(symbol: "point.3.connected.trianglepath.dotted", title: L10n.text("安全访问远端服务"), detail: L10n.text("选择主机后创建 SSH 隧道。"), action: L10n.text("添加主机")) { editingHost = HostProfile() } }
        }
    }
    private var statusBar: some View {
        HStack(spacing: 15) {
            Label(workspace.page == .files ? (workspace.fileHost == nil ? L10n.text("本机文件") : "SFTP") : (showingLocalTerminal ? L10n.text("本机 Shell") : "OpenSSH"), systemImage: showingLocalTerminal ? "terminal" : "lock.shield").foregroundStyle(.secondary)
            Text("UTF-8").foregroundStyle(.tertiary)
            Spacer()
            StatusClock()
            if let terminal = workspace.selectedTerminal, workspace.page == .terminal {
                TerminalStatus(session: terminal, showReconnect: true)
            }
            Text(L10n.text("\(store.hosts.count) 台主机 · \(workspace.sessions.count) 个终端")).foregroundStyle(.secondary)
        }.font(.system(size: 10)).padding(.horizontal, 12).frame(height: 22)
    }
    private func prepareQA() async {
        guard !didPrepareQA, store.isTestWorkspace, let output = ProcessInfo.processInfo.environment["SWB_QA_OUTPUT"] else { return }
        didPrepareQA = true
        let screen = ProcessInfo.processInfo.environment["SWB_QA_SCREEN"] ?? "terminal"
        if screen == "docker-claude-live" {
            do { try await DockerClaudeLiveChecks.run(workspace: workspace, output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "docker-attachments" || screen == "docker-attachment-models" {
            do { try await ContainerAttachmentChecks.run(workspace: workspace, output: URL(fileURLWithPath: output), interactive: screen == "docker-attachments"); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "file-pane-models" || screen == "file-panes" {
            do {
                if screen == "file-pane-models" { try await FilePaneChecks.runModels(store: store) }
                else { try await FilePaneChecks.runUI(workspace: workspace, output: URL(fileURLWithPath: output)) }
                NSApp.terminate(nil)
            } catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "upgrade-compatibility" {
            do { try UpgradeCompatibilityChecks.run(store: store); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "connection-stability" {
            do { try await ConnectionStabilityChecks.run(workspace: workspace); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
            return
        }
        if screen == "workflow-refinements" {
            do { try await WorkflowRefinementChecks.run(workspace: workspace, output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
            return
        }
        if screen == "workspace-tools" {
            do { try await WorkspaceToolsChecks.run(workspace: workspace, output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
            return
        }
        if screen == "large-directory", let directory = ProcessInfo.processInfo.environment["SWB_QA_DIRECTORY"] {
            do { try await LargeDirectoryChecks.run(workspace: workspace, directory: directory); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "terminal-clipboard" {
            do { try await TerminalClipboardChecks.run(workspace: workspace, output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
            return
        }
        if screen == "monitor-sorting" {
            do { try await MonitorProcessSortChecks.run(store: store, output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "terminal-graphics" {
            do { try await TerminalGraphicsChecks.run(workspace: workspace, output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
            return
        }
        if screen == "windows-ssh" {
            do { try await WindowsSSHChecks.run(workspace: workspace, output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
            return
        }
        if screen == "compact-details" {
            do { try await CompactLayoutChecks.run(store: store, output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "attachment-auto" {
            do { try await AttachmentAutoInsertChecks.run(workspace: workspace); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "editor-actions" {
            do { try await EditorChecks.run(store: store, output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "host-monitor" || screen == "local-monitor" {
            if screen == "local-monitor" { workspace.selectedHostID = nil }
            do { try await MonitoringChecks.run(workspace: workspace) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if screen == "terminal-preferences" {
            do { try await TerminalPreferencesChecks.run(workspace: workspace) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
        }
        if screen == "language-settings" {
            do { try await LanguageChecks.run(workspace: workspace, output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if ["navigation-preview", "xml-preview", "media-preview", "java-preview", "python-preview"].contains(screen) {
            do {
                try await FileNavigationMediaChecks.run(workspace: workspace, scene: screen)
                if let model = workspace.currentFileBrowser, let target = model.history.backDestination,
                   let frame = interactionFrames["file.goBack"], let window = NSApp.windows.first(where: { $0.isVisible }), screen == "navigation-preview" {
                    await clickInterface(frame, window: window)
                    for _ in 0..<100 { if !model.busy { break }; try? await Task.sleep(for: .milliseconds(100)) }
                    guard model.path == target else { throw WorkbenchError.message("返回按钮点击无效") }
                    model.load(RemotePath.parent(target))
                    for _ in 0..<100 { if !model.busy { break }; try? await Task.sleep(for: .milliseconds(100)) }
                    if let file = model.files.first(where: { $0.name == "settings.json" }) { model.selection = [file.path]; model.preview(file) }
                    print("PASS · 返回按钮真实点击")
                }
            } catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if screen.hasPrefix("readme-") {
            do { try await ReadmeScreenshots.run(workspace: workspace, scene: String(screen.dropFirst(7)), output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
            return
        }
        if screen == "file-browsing" || screen == "markdown-editor" {
            do { try await FileBrowsingChecks.run(workspace: workspace) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if screen == "compact-workspace" { await verifyTabDragging() }
        if screen == "device-files" {
            guard let host = workspace.host else { exit(1) }
            workspace.browseFiles(.host(host.id))
            let deadline = Date().addingTimeInterval(20)
            while workspace.currentFileBrowser?.files.isEmpty != false {
                if Date() > deadline { fputs("FAIL · 设备文件界面未加载\n", stderr); exit(1) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard workspace.currentFileBrowser?.errorMessage == nil else { fputs("FAIL · 设备文件界面仍有错误\n", stderr); exit(1) }
            print("PASS · 真实设备文件界面正常显示，异常文件名计数：\(workspace.currentFileBrowser?.skippedFileNames ?? 0)")
            if ProcessInfo.processInfo.environment["SWB_QA_DEVICE_LINK"] == "1", let model = workspace.currentFileBrowser {
                let storage = RemotePath.join(model.path, "storage")
                model.load(storage)
                for _ in 0..<100 { if !model.busy { break }; try? await Task.sleep(for: .milliseconds(100)) }
                guard let shared = model.files.first(where: { $0.name == "shared" && $0.attributes.isSymbolicLink }) else { fputs("FAIL · 缺少 shared 目录链接\n", stderr); exit(1) }
                model.selection = [shared.path]; model.preview(shared)
                for _ in 0..<100 { if !model.previewBusy { break }; try? await Task.sleep(for: .milliseconds(100)) }
                guard model.previewTargetIsDirectory, model.errorMessage == nil else { fputs("FAIL · 设备目录链接预览失败\n", stderr); exit(1) }
                model.activate(shared)
                for _ in 0..<100 { if !model.busy && model.path != storage { break }; try? await Task.sleep(for: .milliseconds(100)) }
                guard model.path == "/storage/emulated/0", model.errorMessage == nil else { fputs("FAIL · 设备共享存储链接打开失败\n", stderr); exit(1) }
                print("PASS · 真实 Termux shared 符号链接打开到共享存储，未修改远端文件")
            }
        }
        if screen == "window-titlebar" {
            do { try await WindowTitlebarChecks.run(workspace: workspace) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
        }
        if screen == "file-sorting" {
            do { try await FileSortChecks.run(workspace: workspace) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if screen == "tab-management" {
            do { try await TabManagementChecks.run(workspace: workspace) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
        }
        if ["html-preview", "pdf-preview", "transfer-workflow"].contains(screen) {
            do {
                if screen == "transfer-workflow" { try await TransferWorkflowChecks.run(workspace: workspace) }
                else {
                    try await PreviewChecks.run(workspace: workspace, pdf: screen == "pdf-preview", output: URL(fileURLWithPath: output))
                    if NSApp.isActive, let window = NSApp.keyWindow, let frame = interactionFrames["file.previewDivider"], let model = workspace.currentFileBrowser {
                        let before = model.previewRatio
                        await dragInterface(frame, window: window, offset: -70)
                        guard model.previewRatio > before else { throw WorkbenchError.message("预览分隔条拖动未扩大预览区") }
                        print("PASS · 真实分隔条拖动扩大预览区")
                    } else { print("SKIP · 后台无系统焦点，未派发分隔条拖动") }
                }
            } catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if screen == "update-check" {
            do { try await UpdateChecks.run(output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "pane-layout" {
            do { try await PaneLayoutChecks.run(workspace: workspace) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
        }
        if screen == "file-deletion" {
            do { try await FileDeletionChecks.run(workspace: workspace) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if screen == "terminal-render" {
            do { try TerminalRenderChecks.run(output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if screen == "terminal-zoom" {
            do { try await TerminalZoomChecks.run(workspace: workspace) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
        }
        if screen == "file-switching" { await verifyFileSwitching() }
        if screen == "attachment-check" {
            do { try await AttachmentChecks.run(workspace: workspace) }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.attachmentDraft?.dispose(); workspace.sessions.forEach { $0.close() }; exit(1) }
        }
        if ProcessInfo.processInfo.environment["SWB_QA_INTERACTIONS"] == "1" {
            await verifyTabInteractions()
        }
        if let appearance = ProcessInfo.processInfo.environment["SWB_QA_APPEARANCE"] { store.appearance = appearance }
        if screen == "local-terminal" || screen == "local-mixed" {
            do { try await LocalTerminalChecks.run(workspace: workspace, mixed: screen == "local-mixed") }
            catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); workspace.sessions.forEach { $0.close() }; exit(1) }
        } else if let host = workspace.host {
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
            } else if screen == "files" || screen == "local-files" { workspace.browseFiles(screen == "local-files" ? .local : .host(host.id)) }
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
        let expected: WorkspacePage = ["host-monitor", "local-monitor"].contains(screen) ? .monitor : (["files", "local-files", "file-switching", "file-deletion", "html-preview", "pdf-preview", "file-sorting", "device-files", "file-browsing", "markdown-editor", "navigation-preview", "xml-preview", "media-preview", "java-preview", "python-preview"].contains(screen) ? .files : (screen == "tmux" ? .tmux : (["transfers", "transfer-workflow"].contains(screen) ? .transfers : .terminal)))
        guard workspace.page == expected else {
            fputs("截图验收失败：请求页面与实际工作区不一致。\n", stderr)
            exit(1)
        }
        if expected == .terminal, screen != "host-editor", workspace.selectedTerminal?.connected != true {
            fputs("截图验收失败：终端尚未运行。\n", stderr)
            exit(1)
        }
        let parentWindow = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        if let window = ["host-editor", "markdown-editor"].contains(screen) ? (parentWindow?.sheets.first ?? parentWindow) : parentWindow, let view = window.contentView?.superview {
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
                metadata["terminalKind"] = session.isLocal ? "local" : "ssh"
                metadata["fontSize"] = session.terminal.font.pointSize
            }
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: output + ".json")) }
        } else {
            fputs("截图验收失败：应用没有可见窗口。\n", stderr)
            exit(1)
        }
        if ProcessInfo.processInfo.environment["SWB_QA_EXIT"] == "1" {
            if screen == "markdown-editor", let sheet = parentWindow?.sheets.first {
                parentWindow?.endSheet(sheet); sheet.orderOut(nil)
            }
            if let hold = ProcessInfo.processInfo.environment["SWB_QA_HOLD"], let seconds = Double(hold) { try? await Task.sleep(for: .seconds(min(seconds, 300))) }
            if ["local-terminal", "local-mixed", "file-switching", "attachment-check", "terminal-zoom", "pane-layout", "tab-management", "window-titlebar", "compact-workspace", "terminal-preferences"].contains(screen) { workspace.sessions.forEach { $0.close() } }
            if editingHost != nil { editingHost = nil; try? await Task.sleep(for: .milliseconds(300)) }
            NSApp.terminate(nil)
        }
    }
    @MainActor private func verifyTabDragging() async {
        for _ in 0..<3 { workspace.connectLocal() }
        try? await Task.sleep(for: .seconds(2))
        let first = workspace.sessions[0]; let third = workspace.sessions[2]
        guard let window = first.terminal.window else { exit(1) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.setContentSize(NSSize(width: 1360, height: 860))
        try? await Task.sleep(for: .milliseconds(500))
        func drag(_ source: UUID, _ target: UUID) async {
            guard let start = interactionFrames["terminal.\(source.uuidString)"], let end = interactionFrames["terminal.\(target.uuidString)"] else { exit(1) }
            await dragInterface(start, window: window, offset: end.midX - start.midX)
        }
        for _ in 0..<3 {
            await drag(first.id, third.id)
            guard workspace.layout.tabs.last?.id == first.id else { fputs("FAIL · 真实鼠标向后拖动标签未改变顺序\n", stderr); exit(1) }
            let front = workspace.layout.tabs[0].id
            await drag(first.id, front)
            guard workspace.layout.tabs.first?.id == first.id else { fputs("FAIL · 真实鼠标向前拖动标签未改变顺序\n", stderr); exit(1) }
        }
        let identities = workspace.sessions.map(\.connectionID)
        workspace.page = .files
        try? await Task.sleep(for: .milliseconds(400))
        let layout = workspace.layout; let source = workspace.fileSource
        await drag(first.id, third.id)
        guard workspace.orderedFileSessions.last?.id == first.id, workspace.fileSource == source, workspace.layout == layout else { fputs("FAIL · 文件来源拖动改变了终端分组或选中来源\n", stderr); exit(1) }
        workspace.selectTerminal(first); workspace.page = .terminal
        try? await Task.sleep(for: .milliseconds(500))
        let width = first.terminal.frame.width; let height = first.terminal.frame.height
        guard let sidebarButton = interactionFrames["workspace.sidebar"] else { exit(1) }
        await clickInterface(sidebarButton, window: window)
        guard workspace.sidebarCollapsed, first.terminal.frame.width > width + 190 else { fputs("FAIL · 折叠侧栏未增加终端宽度\n", stderr); exit(1) }
        workspace.showTerminalSearch = true
        try? await Task.sleep(for: .milliseconds(300))
        guard first.terminal.frame.height < height - 20 else { fputs("FAIL · 搜索区未按需展开\n", stderr); exit(1) }
        workspace.showTerminalSearch = false
        try? await Task.sleep(for: .milliseconds(300))
        guard first.terminal.frame.height > window.contentLayoutRect.height * 0.80, workspace.sessions.map(\.connectionID) == identities else { fputs("FAIL · 终端可用高度不足或连接重建：terminal=\(first.terminal.frame) content=\(window.contentLayoutRect) identities=\(workspace.sessions.map(\.connectionID) == identities)\n", stderr); exit(1) }
        print("PASS · 原生标签拖动 6 次、文件来源独立排序、侧栏按钮折叠、搜索按需显示；1360×860 工作区终端 \(Int(first.terminal.frame.width))×\(Int(first.terminal.frame.height))")
    }
    @MainActor private func verifyTabInteractions() async {
        guard let host = workspace.host else { exit(1) }
        workspace.connect(host)
        guard let firstID = workspace.selectedTerminalID else { exit(1) }
        workspace.connect(host, split: true)
        guard let secondID = workspace.splitTerminalID else { exit(1) }
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let secondFrame = interactionFrames["pane.\(secondID.uuidString)"] else { exit(1) }
        await clickInterface(secondFrame, window: window)
        guard workspace.splitTerminalID == secondID, workspace.layout.primary == firstID, workspace.selectedTerminalID == secondID else {
            fputs("FAIL · 点击分屏终端标签后布局被清空\n", stderr); exit(1)
        }
        guard let firstFrame = interactionFrames["pane.\(firstID.uuidString)"] else { exit(1) }
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
    @MainActor private func verifyFileSwitching() async {
        guard let host = workspace.host else { fputs("FAIL · 缺少隔离测试主机\n", stderr); exit(1) }
        workspace.connect(host)
        guard let first = workspace.selectedTerminal else { exit(1) }
        workspace.connect(host, split: true)
        guard let second = workspace.selectedTerminal else { exit(1) }
        workspace.page = .files
        try? await Task.sleep(for: .seconds(2))
        guard interactionFrames["terminal.\(first.id.uuidString)"] != nil,
              interactionFrames["terminal.\(second.id.uuidString)"] != nil else {
            fputs("FAIL · 文件页没有终端标签，无法直接切换文件所属会话\n", stderr); exit(1)
        }
        let layout = workspace.layout
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let firstFrame = interactionFrames["terminal.\(first.id.uuidString)"] else { exit(1) }
        await clickInterface(firstFrame, window: window)
        guard workspace.fileSource == .terminal(first.id), let firstBrowser = workspace.currentFileBrowser else { fputs("FAIL · 文件来源未切换到第一会话\n", stderr); exit(1) }
        firstBrowser.load("/home/tester/workspace/projects")
        for _ in 0..<100 { if !firstBrowser.busy && firstBrowser.path.hasSuffix("/projects") { break }; try? await Task.sleep(for: .milliseconds(100)) }
        firstBrowser.filter = "部署"; firstBrowser.selection = ["/home/tester/workspace/projects/部署说明.md"]
        guard let secondFrame = interactionFrames["terminal.\(second.id.uuidString)"] else { exit(1) }
        await clickInterface(secondFrame, window: window)
        guard let secondBrowser = workspace.currentFileBrowser, secondBrowser !== firstBrowser else { fputs("FAIL · 同主机会话共享了同一文件浏览状态\n", stderr); exit(1) }
        secondBrowser.load("/home/tester/workspace/logs")
        for _ in 0..<100 { if !secondBrowser.busy && secondBrowser.path.hasSuffix("/logs") { break }; try? await Task.sleep(for: .milliseconds(100)) }
        await clickInterface(firstFrame, window: window)
        guard workspace.currentFileBrowser === firstBrowser, firstBrowser.path.hasSuffix("/projects"), firstBrowser.filter == "部署",
              firstBrowser.selection.contains("/home/tester/workspace/projects/部署说明.md"), workspace.layout == layout else {
            fputs("FAIL · 文件会话切换丢失目录/筛选/选择或影响了终端布局\n", stderr); exit(1)
        }
        workspace.browseFiles(.local)
        guard workspace.fileHost == nil, workspace.currentFileBrowser !== firstBrowser, workspace.layout == layout else { exit(1) }
        if let other = store.hosts.first(where: { $0.id != host.id }) {
            workspace.browseFiles(.host(other.id))
            guard workspace.currentFileBrowser?.host?.id == other.id, workspace.layout == layout else { exit(1) }
        }
        workspace.browseFiles(.terminal(first.id))
        guard workspace.sessionLabel(first) != workspace.sessionLabel(second), workspace.layout == layout else { exit(1) }
        print("PASS · 文件页真实点击会话标签、同主机独立目录/筛选/选择、本机及其他主机来源、终端布局保持")
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
    alert.addButton(withTitle: L10n.text("确认")); alert.addButton(withTitle: L10n.text("取消"))
    return alert.runModal() == .alertFirstButtonReturn
}
