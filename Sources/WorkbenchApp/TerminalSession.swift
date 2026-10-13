import AppKit
import SwiftUI
import SwiftTerm
import WorkbenchCore
import OpenSSHBackend

final class SafeTerminalView: LocalProcessTerminalView {
    private var proxy: TerminalSecurityProxy!
    override init(frame: CGRect) {
        super.init(frame: frame)
        proxy = TerminalSecurityProxy(owner: self); terminalDelegate = proxy
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func paste(_ sender: Any) {
        if let text = NSPasteboard.general.string(forType: .string), text.contains("\n") || text.contains("\r") {
            let alert = NSAlert(); alert.messageText = "粘贴多行内容？"; alert.informativeText = "内容可能包含会立即执行的命令。\n\n" + String(text.prefix(700)); alert.addButton(withTitle: "粘贴"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        super.paste(sender)
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
            let alert = NSAlert(); alert.messageText = "允许此终端写入 Mac 剪贴板？"; alert.informativeText = "远端请求复制内容（例如 tmux 复制模式）。读取本机剪贴板的远端请求始终被拒绝。"; alert.addButton(withTitle: "允许本终端写入"); alert.addButton(withTitle: "拒绝")
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
    let host: HostProfile
    let tmuxID: String?
    let terminal = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
    @Published var title: String
    @Published var state = "待连接"
    @Published var connected = false
    @Published var dimensions = ""
    private var started = false
    private var disposed = false
    private var pendingReconnect = false
    private var probe = CancellationFlag()
    private let transport: SSHTransport
    init(host: HostProfile, tmuxID: String? = nil, transport: SSHTransport) {
        self.host = host; self.tmuxID = tmuxID; self.transport = transport
        title = tmuxID == nil ? host.name : "tmux · \(host.name)"
        super.init()
        terminal.processDelegate = self; terminal.optionAsMetaKey = true
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.getTerminal().changeScrollback(10000)
    }
    func start() {
        guard !started, !disposed else { return }; started = true; state = "正在验证连接…"; probe = CancellationFlag()
        let transport = transport; let host = host; let cancellation = probe
        Task {
            do {
                _ = try await Task.detached { try transport.run(host, command: "true", cancellation: cancellation, timeout: 120).checked() }.value
                guard !disposed, !cancellation.isCancelled else { return }
                terminal.startProcess(executable: "/usr/bin/ssh", args: try transport.terminalArguments(for: host, tmuxSession: tmuxID), environment: transport.environment(for: host).map { "\($0.key)=\($0.value)" })
                connected = true; state = "已连接"
                terminal.window?.makeFirstResponder(terminal)
            } catch {
                guard !disposed, !cancellation.isCancelled else { return }; state = "连接失败"; connected = false
                terminal.feed(text: "\r\n\u{1b}[31m\(error.localizedDescription.replacingOccurrences(of: "\n", with: "\r\n"))\u{1b}[0m\r\n")
            }
        }
    }
    func reconnect() {
        probe.cancel(); disposed = false
        if terminal.process.running { pendingReconnect = true; terminal.terminate() }
        else { started = false; start() }
    }
    func close() { disposed = true; probe.cancel(); terminal.terminate(); connected = false; state = "已断开" }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) { DispatchQueue.main.async { [weak self] in self?.dimensions = "\(newCols) × \(newRows)" } }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) { DispatchQueue.main.async { [weak self] in if !title.isEmpty { self?.title = String(title.prefix(100)) } } }
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) { DispatchQueue.main.async { [weak self] in if !title.isEmpty { self?.title = String(title.prefix(100)) } } }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; connected = false; state = exitCode == 0 ? "已断开" : "连接已中断"
            if pendingReconnect && !disposed { pendingReconnect = false; started = false; start() }
        }
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) var colorScheme
    func makeNSView(context: Context) -> SafeTerminalView {
        DispatchQueue.main.async { session.start() }
        return session.terminal
    }
    func updateNSView(_ view: SafeTerminalView, context: Context) {
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
    @Published var page: WorkspacePage = .terminal { didSet { alignTerminalWithHost() } }
    @Published var sessions: [TerminalSession] = []
    @Published var layout = TerminalLayout()
    @Published var browsingLocalFiles = false
    @Published var showTransferTray = false
    @Published var hostSearch = ""
    let store: AppStore
    init(store: AppStore) { self.store = store; selectedHostID = store.hosts.first?.id }
    var host: HostProfile? { store.hosts.first { $0.id == selectedHostID } }
    var selectedTerminalID: UUID? { layout.focused }
    var splitTerminalID: UUID? { layout.secondary }
    var selectedTerminal: TerminalSession? { sessions.first { $0.id == layout.focused } }
    var primaryTerminal: TerminalSession? { sessions.first { $0.id == layout.primary } }
    private func alignTerminalWithHost() {
        if page == .terminal, selectedTerminal?.host.id != selectedHostID {
            if let session = sessions.last(where: { $0.host.id == selectedHostID }) { layout.select(session.id) }
        }
    }
    func connect(_ host: HostProfile, tmux: String? = nil, split: Bool = false, sessionName: String? = nil) {
        let preserveSplit = split && layout.primary != nil
        let session = TerminalSession(host: host, tmuxID: tmux, transport: store.transport)
        sessions.append(session)
        if preserveSplit { layout.split(with: session.id) } else { layout.select(session.id) }
        selectedHostID = host.id
        page = .terminal
        if let tmux { store.rememberSession(host, session: sessionName ?? tmux) }
    }
    func selectTerminal(_ session: TerminalSession) {
        layout.select(session.id); selectedHostID = session.host.id
        session.terminal.window?.makeFirstResponder(session.terminal)
    }
    func collapseSplit() { layout.collapse() }
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
        session.close(); sessions.removeAll { $0.id == session.id }
        layout.close(session.id, fallback: sessions.last(where: { $0.host.id == selectedHostID })?.id ?? sessions.last?.id)
    }
}

enum WorkspacePage: String, CaseIterable {
    case terminal = "终端", tmux = "tmux 会话", files = "文件", transfers = "传输", tunnels = "隧道"
    var symbol: String {
        switch self { case .terminal: return "terminal"; case .tmux: return "square.stack.3d.up"; case .files: return "folder"; case .transfers: return "arrow.left.arrow.right"; case .tunnels: return "point.3.connected.trianglepath.dotted" }
    }
}
