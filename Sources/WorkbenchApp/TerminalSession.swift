import AppKit
import SwiftUI
import SwiftTerm
import WorkbenchCore
import OpenSSHBackend

final class SafeTerminalView: LocalProcessTerminalView {
    private var proxy: TerminalSecurityProxy!
    var attachmentStagingRoot: URL?
    var onAttachments: ((TerminalAttachmentPayload) -> Void)?
    var onAttachmentFailure: ((String) -> Void)?
    var onInputActivity: (() -> Void)?
    var onFontScale: ((Double, Bool) -> Void)?
    var onFocus: (() -> Void)?
    var shouldRequestFocus = false
    private var magnificationBase: Double?
    private var accumulatedMagnification: Double = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        proxy = TerminalSecurityProxy(owner: self); terminalDelegate = proxy
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onFocus?()
    }
    override func magnify(with event: NSEvent) { applyMagnification(Double(event.magnification), phase: event.phase) }
    func applyMagnification(_ delta: Double, phase: NSEvent.Phase) {
        guard delta.isFinite else { return }
        if magnificationBase == nil || phase.contains(.began) { magnificationBase = Double(font.pointSize); accumulatedMagnification = 0 }
        guard let base = magnificationBase else { return }
        if phase.contains(.cancelled) {
            onFontScale?(base, false); magnificationBase = nil; accumulatedMagnification = 0; return
        }
        accumulatedMagnification += delta
        let ended = phase.contains(.ended) || phase.isEmpty
        onFontScale?(TerminalFontSize.scaled(base: base, magnification: accumulatedMagnification), ended)
        if ended { magnificationBase = nil; accumulatedMagnification = 0 }
    }
    override func paste(_ sender: Any) {
        if receiveAttachments(from: NSPasteboard.general) { return }
        if let text = NSPasteboard.general.string(forType: .string), text.contains("\n") || text.contains("\r") {
            let alert = NSAlert(); alert.messageText = "粘贴多行内容？"; alert.informativeText = "内容可能包含会立即执行的命令。\n\n" + String(text.prefix(700)); alert.addButton(withTitle: "粘贴"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        super.paste(sender)
    }
    @discardableResult func receiveAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard let root = attachmentStagingRoot, let onAttachments else { return false }
        do {
            if let payload = try TerminalAttachmentPayload.read(pasteboard, stagingRoot: root) { onAttachments(payload); return true }
        } catch { onAttachmentFailure?(error.localizedDescription); return true }
        return false
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onAttachments != nil, sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil else { return [] }
        layer?.borderWidth = 2; layer?.borderColor = NSColor.systemTeal.cgColor
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        return receiveAttachments(from: sender.draggingPasteboard)
    }
    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { onInputActivity?(); super.send(source: source, data: data) }
    func sendAttachmentReference(_ text: String) {
        let bracketed = getTerminal().bracketedPasteMode
        if bracketed { process.send(data: Array("\u{1b}[200~".utf8)[...]) }
        process.send(data: Array(text.utf8)[...])
        if bracketed { process.send(data: Array("\u{1b}[201~".utf8)[...]) }
    }
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        let alert = NSAlert(); alert.messageText = "在浏览器中打开链接？"; alert.informativeText = url.absoluteString; alert.addButton(withTitle: "打开"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }
}

private final class TerminalSecurityProxy: TerminalViewDelegate {
    weak var owner: SafeTerminalView?
    private var clipboardDecision: Bool?
    init(owner: SafeTerminalView) { self.owner = owner }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { owner?.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { owner?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { owner?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { owner?.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { owner?.scrolled(source: source, position: position) }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { owner?.requestOpenLink(source: source, link: link, params: params) }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func clipboardCopy(source: TerminalView, content: Data) {
        guard content.count <= 1024 * 1024 else { return }
        if clipboardDecision == nil {
            let alert = NSAlert(); alert.messageText = "允许此终端写入 Mac 剪贴板？"; alert.informativeText = "终端程序请求复制内容（例如 tmux 复制模式）。通过终端协议读取剪贴板的请求始终被拒绝。"; alert.addButton(withTitle: "允许本终端写入"); alert.addButton(withTitle: "拒绝")
            clipboardDecision = alert.runModal() == .alertFirstButtonReturn
        }
        if clipboardDecision == true { owner?.clipboardCopy(source: source, content: content) }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let host: HostProfile?
    let tmuxID: String?
    let terminal = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
    @Published var title: String
    @Published var state = "待连接"
    @Published var connected = false
    @Published var dimensions = ""
    private(set) var connectionID = UUID()
    private(set) var inputGeneration: UInt64 = 0
    private var started = false
    private var disposed = false
    private var pendingReconnect = false
    private var probe = CancellationFlag()
    private let transport: SSHTransport
    var isLocal: Bool { host == nil }
    var displayName: String { host?.name ?? "此 Mac" }
    var subtitle: String { host?.subtitle ?? "\(NSUserName()) · \(LocalShellConfiguration.userShell) · 登录 Shell" }
    var restartLabel: String { isLocal ? "重新打开" : "重连" }
    init(host: HostProfile? = nil, tmuxID: String? = nil, transport: SSHTransport) {
        self.host = host; self.tmuxID = tmuxID; self.transport = transport
        title = tmuxID == nil ? (host?.name ?? "此 Mac") : "tmux · \(host?.name ?? "此 Mac")"
        super.init()
        state = isLocal ? "待启动" : "待连接"
        terminal.processDelegate = self; terminal.optionAsMetaKey = true
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.getTerminal().changeScrollback(10000)
        terminal.onInputActivity = { [weak self] in self?.inputGeneration &+= 1 }
    }
    func start() {
        guard !started, !disposed else { return }; started = true; state = isLocal ? "正在启动…" : "正在验证连接…"; probe = CancellationFlag()
        connectionID = UUID()
        let transport = transport; let host = host; let cancellation = probe
        Task {
            do {
                guard !disposed, !cancellation.isCancelled else { return }
                if let host {
                    _ = try await Task.detached { try transport.run(host, command: "true", cancellation: cancellation, timeout: 120).checked() }.value
                    guard !disposed, !cancellation.isCancelled else { return }
                    terminal.startProcess(executable: "/usr/bin/ssh", args: try transport.terminalArguments(for: host, tmuxSession: tmuxID), environment: transport.environment(for: host).map { "\($0.key)=\($0.value)" })
                } else {
                    let configuration = try LocalShellConfiguration()
                    var environment = configuration.environment
                    environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
                    if let tmuxID {
                        terminal.startProcess(executable: try TmuxService.localExecutable(), args: ["attach-session", "-t", tmuxID], environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: configuration.directory)
                    } else {
                        terminal.startProcess(executable: configuration.executable, environment: environment.map { "\($0.key)=\($0.value)" }, execName: configuration.executableName, currentDirectory: configuration.directory)
                    }
                }
                guard terminal.process.running else { throw WorkbenchError.message("无法启动终端进程，请重新打开终端。") }
                connected = true; state = isLocal ? "运行中" : "已连接"
                if terminal.shouldRequestFocus { terminal.window?.makeFirstResponder(terminal) }
            } catch {
                guard !disposed, !cancellation.isCancelled else { return }; state = isLocal ? "启动失败" : "连接失败"; connected = false
                terminal.feed(text: "\r\n\u{1b}[31m\(error.localizedDescription.replacingOccurrences(of: "\n", with: "\r\n"))\u{1b}[0m\r\n")
            }
        }
    }
    func reconnect() {
        probe.cancel(); disposed = false
        if terminal.process.running { pendingReconnect = true; terminal.terminate() }
        else { started = false; start() }
    }
    func close() { disposed = true; pendingReconnect = false; probe.cancel(); terminal.terminate(); connected = false; state = isLocal ? "已结束" : "已断开" }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) { DispatchQueue.main.async { [weak self] in self?.dimensions = "\(newCols) × \(newRows)" } }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) { DispatchQueue.main.async { [weak self] in if !title.isEmpty { self?.title = String(title.prefix(100)) } } }
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) { DispatchQueue.main.async { [weak self] in if !title.isEmpty { self?.title = String(title.prefix(100)) } } }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; connected = false
            state = isLocal ? (exitCode == 0 || disposed ? "已结束" : "进程已退出") : (exitCode == 0 ? "已断开" : "连接已中断")
            if pendingReconnect && !disposed { pendingReconnect = false; started = false; start() }
        }
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) var colorScheme
    var focused: Bool
    func makeNSView(context: Context) -> SafeTerminalView {
        DispatchQueue.main.async { session.start() }
        return session.terminal
    }
    func updateNSView(_ view: SafeTerminalView, context: Context) {
        view.shouldRequestFocus = focused
        let size = CGFloat(store.fontSize)
        let font = NSFont(name: store.fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let background = colorScheme == .dark ? NSColor(red: 0.055, green: 0.067, blue: 0.083, alpha: 1) : NSColor(red: 0.975, green: 0.98, blue: 0.983, alpha: 1)
        let foreground = colorScheme == .dark ? NSColor(red: 0.83, green: 0.87, blue: 0.9, alpha: 1) : NSColor(red: 0.13, green: 0.18, blue: 0.22, alpha: 1)
        if view.font != font { view.font = font }
        if view.nativeBackgroundColor != background { view.nativeBackgroundColor = background }
        if view.nativeForegroundColor != foreground { view.nativeForegroundColor = foreground }
        if view.caretColor != NSColor.systemTeal { view.caretColor = NSColor.systemTeal }
    }
}

@MainActor
final class Workspace: ObservableObject {
    @Published var selectedHostID: UUID? { didSet { alignTerminalWithHost() } }
    @Published var page: WorkspacePage = .terminal {
        didSet {
            if page == .files, oldValue != .files, fileSource == nil { followCurrentTerminalFiles() }
            if page == .terminal { alignTerminalWithHost() }
        }
    }
    @Published var sessions: [TerminalSession] = []
    @Published var layout = TerminalLayout()
    @Published var browsingLocalFiles = false
    @Published var showTransferTray = false
    @Published var hostSearch = ""
    @Published var fileSource: FileBrowserSource?
    @Published var attachmentDraft: TerminalAttachmentDraft?
    private var focusGeneration: UInt64 = 0
    private var fileBrowsers: [FileBrowserSource: FileModel] = [:]
    private var terminalNumbers: [UUID: Int] = [:]
    private var hostTerminalCounts: [UUID?: Int] = [:]
    let store: AppStore
    init(store: AppStore) { self.store = store; selectedHostID = store.hosts.first?.id }
    var host: HostProfile? { store.hosts.first { $0.id == selectedHostID } }
    var selectedTerminalID: UUID? { layout.focused }
    var splitTerminalID: UUID? { layout.secondary }
    var selectedTerminal: TerminalSession? { sessions.first { $0.id == layout.focused } }
    var primaryTerminal: TerminalSession? { sessions.first { $0.id == layout.primary } }
    var fileHost: HostProfile? {
        switch fileSource {
        case .terminal(let identifier): return sessions.first(where: { $0.id == identifier })?.host
        case .host(let identifier): return store.hosts.first(where: { $0.id == identifier })
        default: return nil
        }
    }
    var fileSourceAvailable: Bool {
        switch fileSource {
        case .terminal(let identifier): return sessions.contains { $0.id == identifier }
        case .host(let identifier): return store.hosts.contains { $0.id == identifier }
        case .local: return true
        case nil: return false
        }
    }
    var activeTabID: UUID? { page == .files ? fileSource?.terminalID : selectedTerminalID }
    var fileSourceName: String {
        if let identifier = fileSource?.terminalID, let session = sessions.first(where: { $0.id == identifier }) { return sessionLabel(session) }
        return fileHost.map { "\($0.name) · 主机文件" } ?? "此 Mac · 本地文件"
    }
    var currentFileBrowser: FileModel? {
        guard fileSourceAvailable, let source = fileSource else { return nil }
        return fileBrowser(for: source, host: fileHost)
    }
    private func fileBrowser(for source: FileBrowserSource, host: HostProfile?) -> FileModel {
        if let existing = fileBrowsers[source], existing.host?.connectionKey == host?.connectionKey { return existing }
        fileBrowsers[source]?.stop()
        let browser = FileModel(host: host, store: store)
        fileBrowsers[source] = browser
        return browser
    }
    func sessionLabel(_ session: TerminalSession) -> String {
        "\(session.displayName) · \(session.isLocal ? "本机" : (session.tmuxID == nil ? "终端" : "tmux")) \(terminalNumbers[session.id] ?? 1)"
    }
    private func register(_ session: TerminalSession) {
        let next = (hostTerminalCounts[session.host?.id] ?? 0) + 1
        hostTerminalCounts[session.host?.id] = next; terminalNumbers[session.id] = next
        sessions.append(session)
        session.terminal.onFocus = { [weak self, weak session] in
            guard let self, let session, page == .terminal,
                  layout.selectedTab?.terminals.contains(session.id) == true, selectedTerminalID != session.id else { return }
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session, session.terminal.window?.firstResponder === session.terminal,
                      layout.selectedTab?.terminals.contains(session.id) == true else { return }
                selectTerminal(session)
            }
        }
        session.terminal.attachmentStagingRoot = store.paths.root.appendingPathComponent("attachment-staging")
        session.terminal.onAttachments = { [weak self, weak session] payload in
            guard let self, let session else { return }
            requestAttachments(session: session, payload: payload)
        }
        session.terminal.onAttachmentFailure = { [weak self] error in self?.store.errorMessage = error }
        session.terminal.onFontScale = { [weak self] size, finished in
            self?.store.fontSize = size
            if finished { self?.store.savePreferences() }
        }
    }
    func attachmentIdentity(_ session: TerminalSession) -> AttachmentDeliveryIdentity {
        let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        return AttachmentDeliveryIdentity(sessionID: session.id, connectionID: session.connectionID, focusGeneration: focusGeneration, inputGeneration: session.inputGeneration,
                                          windowNumber: window?.windowNumber, applicationActive: NSApp.isActive)
    }
    func requestAttachments(session: TerminalSession, payload: TerminalAttachmentPayload) {
        guard session.connected, sessions.contains(where: { $0.id == session.id }), attachmentDraft?.busy != true else {
            if let temporary = payload.temporaryDirectory { try? FileManager.default.removeItem(at: temporary) }
            store.errorMessage = "终端未连接或已有附件任务，请先完成当前操作。"; return
        }
        attachmentDraft?.dispose(); attachmentDraft = nil
        selectTerminal(session); page = .terminal
        attachmentDraft = TerminalAttachmentDraft(session: session, payload: payload, workspace: self)
    }
    func chooseAttachments() {
        guard let session = selectedTerminal, session.connected else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.prompt = "发送到此终端"
        if panel.runModal() == .OK { requestAttachments(session: session, payload: TerminalAttachmentPayload(files: panel.urls, temporaryDirectory: nil)) }
    }
    func chooseTab(_ session: TerminalSession) {
        focusGeneration &+= 1
        if page == .files { fileSource = .terminal(session.id) }
        else { selectTerminal(session) }
    }
    func followCurrentTerminalFiles() {
        if let session = selectedTerminal { fileSource = .terminal(session.id) }
        else { fileSource = host.map { .host($0.id) } ?? .local }
    }
    func browseFiles(_ source: FileBrowserSource) {
        focusGeneration &+= 1
        fileSource = source; page = .files
    }
    func selectHost(_ host: HostProfile) {
        if page == .files { browseFiles(.host(host.id)) }
        else { browsingLocalFiles = false; selectedHostID = host.id }
    }
    func openFileSourceTerminal() {
        if let identifier = fileSource?.terminalID, let session = sessions.first(where: { $0.id == identifier }) {
            selectTerminal(session); page = .terminal
        } else if let host = fileHost { connect(host) }
        else if fileSource == .local { connectLocal() }
    }
    private func alignTerminalWithHost() {
        if page == .terminal, selectedTerminal?.host?.id != selectedHostID {
            if let session = sessions.last(where: { $0.host?.id == selectedHostID }) { layout.select(session.id) }
        }
    }
    func connect(_ host: HostProfile, tmux: String? = nil, split: Bool = false, sessionName: String? = nil, axis: TerminalSplitAxis = .leftRight) {
        let preserveSplit = split && layout.primary != nil
        let session = TerminalSession(host: host, tmuxID: tmux, transport: store.transport)
        register(session)
        if preserveSplit { layout.split(with: session.id, axis: axis) } else { layout.select(session.id) }
        fileSource = .terminal(session.id)
        browsingLocalFiles = false
        selectedHostID = host.id
        page = .terminal
        if let tmux { store.rememberSession(host, session: sessionName ?? tmux) }
    }
    func connectLocal(split: Bool = false, tmux: String? = nil, axis: TerminalSplitAxis = .leftRight) {
        let session = TerminalSession(tmuxID: tmux, transport: store.transport)
        register(session)
        if split && layout.primary != nil { layout.split(with: session.id, axis: axis) } else { layout.select(session.id) }
        fileSource = .terminal(session.id)
        browsingLocalFiles = true; selectedHostID = nil; page = .terminal
    }
    func openLocalTerminal() {
        if let session = sessions.last(where: \.isLocal) { selectTerminal(session); page = .terminal }
        else { connectLocal() }
    }
    func attachTmux(_ host: HostProfile?, session: TmuxSession) {
        if let host { connect(host, tmux: session.id, sessionName: session.name) } else { connectLocal(tmux: session.id) }
    }
    func newTerminal(split: Bool = false, axis: TerminalSplitAxis = .leftRight) {
        if let host { connect(host, split: split, axis: axis) } else { connectLocal(split: split, axis: axis) }
    }
    func selectTerminal(_ session: TerminalSession) {
        focusGeneration &+= 1
        layout.select(session.id); browsingLocalFiles = session.isLocal; selectedHostID = session.host?.id
        fileSource = .terminal(session.id)
        session.terminal.window?.makeFirstResponder(session.terminal)
    }
    func chooseTerminalTab(_ identifier: UUID) {
        guard let tab = layout.tabs.first(where: { $0.id == identifier }), let session = sessions.first(where: { $0.id == tab.focused }) else { return }
        selectTerminal(session)
    }
    func focusNextPane(backward: Bool = false) {
        layout.focusNext(backward: backward)
        if let session = selectedTerminal { selectTerminal(session) }
    }
    func selectNextTab(backward: Bool = false) {
        layout.selectNextTab(backward: backward)
        if let session = selectedTerminal { selectTerminal(session) }
    }
    func togglePaneZoom() { layout.toggleZoom() }
    func confirmClosePane(_ session: TerminalSession) {
        let detail = session.tmuxID != nil ? "只分离此终端，tmux 会话继续运行。" : "当前 Shell 和前台任务可能随连接关闭。"
        if session.connected && !confirm("关闭此分栏？", detail) { return }
        close(session)
    }
    func closeTab(_ identifier: UUID) {
        guard let tab = layout.tabs.first(where: { $0.id == identifier }) else { return }
        let closing = sessions.filter { tab.terminals.contains($0.id) }
        if closing.contains(where: \.connected) && !confirm("关闭此标签的 \(closing.count) 个终端？", "普通 Shell 和前台任务可能结束；tmux 只分离，不结束远端会话。其他标签不受影响。") { return }
        closing.forEach { close($0) }
    }
    func connectPreferred(_ host: HostProfile) {
        selectedHostID = host.id
        guard host.prefersTmux else { connect(host); return }
        page = .tmux
        guard !host.lastSession.isEmpty else { return }
        let service = TmuxService(transport: store.transport, host: host)
        Task {
            if let sessions = try? await Task.detached(operation: { try service.sessions() }).value,
               let session = sessions.first(where: { $0.name == host.lastSession || $0.id == host.lastSession }), selectedHostID == host.id {
                connect(host, tmux: session.id, sessionName: session.name)
            }
        }
    }
    func close(_ session: TerminalSession) {
        if attachmentDraft?.session.id == session.id { attachmentDraft?.dispose(); attachmentDraft = nil }
        let source = FileBrowserSource.terminal(session.id)
        if fileSource == source {
            let next = sessions.last(where: { $0.id != session.id })
            fileSource = next.map { .terminal($0.id) } ?? session.host.map { .host($0.id) } ?? .local
        }
        fileBrowsers.removeValue(forKey: source)?.stop()
        terminalNumbers.removeValue(forKey: session.id)
        session.close(); sessions.removeAll { $0.id == session.id }
        layout.close(session.id, fallback: sessions.last(where: { $0.host?.id == selectedHostID })?.id ?? sessions.last?.id)
        if let selectedTerminal { browsingLocalFiles = selectedTerminal.isLocal; selectedHostID = selectedTerminal.host?.id }
    }
}

enum WorkspacePage: String, CaseIterable {
    case terminal = "终端", tmux = "tmux 会话", files = "文件", transfers = "传输", tunnels = "隧道"
    var symbol: String {
        switch self { case .terminal: return "terminal"; case .tmux: return "square.stack.3d.up"; case .files: return "folder"; case .transfers: return "arrow.left.arrow.right"; case .tunnels: return "point.3.connected.trianglepath.dotted" }
    }
}
