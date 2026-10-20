import AppKit
import SwiftUI
import SwiftTerm
import WorkbenchCore
import OpenSSHBackend
import Combine
import Darwin

private final class TmuxRightMouseEvent: NSEvent {
    let original: NSEvent
    init(_ original: NSEvent) { self.original = original; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var buttonNumber: Int { 2 }
    override var type: NSEvent.EventType { original.type }
    override var locationInWindow: NSPoint { original.locationInWindow }
    override var modifierFlags: NSEvent.ModifierFlags { original.modifierFlags.union(.option) }
    override var clickCount: Int { original.clickCount }
}

final class SafeTerminalView: LocalProcessTerminalView {
    let clipboard = TerminalClipboardState()
    private var proxy: TerminalSecurityProxy!
    var attachmentStagingRoot: URL?
    var onAttachments: ((TerminalAttachmentPayload) -> Void)?
    var onAttachmentFailure: ((String) -> Void)?
    var onInputActivity: (() -> Void)?
    var onFontScale: ((Double, Bool) -> Void)?
    var onFocus: (() -> Void)?
    var shouldRequestFocus = false
    var onContextFocus: (() -> Void)?
    var prefersTmuxMenu: (() -> Bool)?
    var prepareTmuxMenu: (() -> Void)?
    var semanticCommandCopyAllowed = true
    var remoteSelectionContext = false
    var commandCapture = SemanticCommandCapture()
    private var shellMarkers = ShellMarkerStream()
    private(set) var observedProcessExit = true
    private var forwardedRightClick = false
    private var localSelectionDrag = false
    private var magnificationBase: Double?
    private var accumulatedMagnification: Double = 0
    private var scrollMonitor: Any?
    private var graphicsInput = TerminalGraphicsInput()
    var displayedGraphicsImages: Int { graphicsInput.displayedImages }
    override init(frame: CGRect) {
        var options = SwiftTerm.TerminalOptions.default
        options.kittyImageCacheLimitBytes = 64 * 1024 * 1024
        super.init(frame: frame, options: options)
        proxy = TerminalSecurityProxy(owner: self); terminalDelegate = proxy
        registerForDraggedTypes([.fileURL, .png, .tiff])
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
               self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.noteMouseInput(event) }
            return event
        }
    }
    deinit { if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) } }
    override func dataReceived(slice: ArraySlice<UInt8>) {
        let filtered = graphicsInput.filter(slice)
        guard !filtered.isEmpty else { return }
        var offset = 0
        for event in shellMarkers.scan(filtered) {
            super.dataReceived(slice: filtered[offset..<event.endIndex])
            if semanticCommandCopyAllowed { commandCapture.receive(event.action, terminal: getTerminal()) }
            offset = event.endIndex
        }
        if offset < filtered.count { super.dataReceived(slice: filtered[offset...]) }
    }
    func resetGraphicsInput() { graphicsInput = TerminalGraphicsInput(); shellMarkers = ShellMarkerStream(); commandCapture.reset() }
    func prepareProcessStart() { observedProcessExit = false }
    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        observedProcessExit = true
        super.processTerminated(source, exitCode: exitCode)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func mouseDown(with event: NSEvent) {
        clipboard.noteUserInteraction()
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        localSelectionDrag = event.modifierFlags.contains(.shift)
        if localSelectionDrag { withLocalSelection { super.mouseDown(with: event) } }
        else { noteMouseInput(event); super.mouseDown(with: event) }
        onFocus?()
    }
    override func rightMouseDown(with event: NSEvent) {
        noteMouseInput(event)
        window?.makeFirstResponder(self); onContextFocus?()
        forwardedRightClick = false
        if !selectionActive && prefersTmuxMenu?() == true && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.control) {
            if allowMouseReporting && getTerminal().mouseMode != .off {
                forwardedRightClick = true; super.mouseDown(with: TmuxRightMouseEvent(event))
                return
            }
            prepareTmuxMenu?()
        }
        NSMenu.popUpContextMenu(ordinaryContextMenu(), with: event, for: self)
    }
    override func rightMouseUp(with event: NSEvent) {
        if forwardedRightClick { forwardedRightClick = false; super.mouseUp(with: TmuxRightMouseEvent(event)) }
    }
    override func mouseUp(with event: NSEvent) {
        if localSelectionDrag { withLocalSelection { super.mouseUp(with: event) }; localSelectionDrag = false; return }
        if !event.modifierFlags.contains(.control) { super.mouseUp(with: event) }
    }
    override func rightMouseDragged(with event: NSEvent) {
        noteMouseInput(event)
        if forwardedRightClick { super.mouseDragged(with: TmuxRightMouseEvent(event)) }
    }
    override func mouseDragged(with event: NSEvent) {
        if localSelectionDrag { withLocalSelection { super.mouseDragged(with: event) } }
        else { noteMouseInput(event); super.mouseDragged(with: event) }
    }
    private func withLocalSelection(_ action: () -> Void) {
        let original = allowMouseReporting
        allowMouseReporting = false
        defer { allowMouseReporting = original }
        action()
    }
    override func selectionChanged(source: SwiftTerm.Terminal) {
        super.selectionChanged(source: source)
        clipboard.hasSelection = selectionActive && !(getSelection() ?? "").isEmpty
    }
    override func copy(_ sender: Any) {
        guard let text = getSelection(), !text.isEmpty else {
            clipboard.noLocalSelection(remoteContext: remoteSelectionContext || (allowMouseReporting && getTerminal().mouseMode != .off)); return
        }
        clipboard.write(text)
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command {
            if event.charactersIgnoringModifiers?.lowercased() == "c" { copy(self); return true }
            if event.charactersIgnoringModifiers?.lowercased() == "v" { paste(self); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
    private func noteMouseInput(_ event: NSEvent) {
        if allowMouseReporting, getTerminal().mouseMode != .off, !event.modifierFlags.contains(.shift) { clipboard.noteUserInteraction(); onInputActivity?() }
    }
    func ordinaryContextMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; entry.isEnabled = enabled; menu.addItem(entry)
        }
        item(L10n.text("复制"), #selector(contextCopy), enabled: selectionActive)
        item(L10n.text("复制所选命令全文"), #selector(contextCommandCopy), enabled: selectionActive && semanticCommandCopyAllowed)
        item(L10n.text("复制所选命令的输出"), #selector(contextOutputCopy), enabled: selectionActive && semanticCommandCopyAllowed)
        item(L10n.text("粘贴"), #selector(contextPaste), enabled: process.running && NSPasteboard.general.availableType(from: [.string, .fileURL, .png, .tiff]) != nil)
        menu.addItem(.separator())
        item(L10n.text("全选"), #selector(contextSelectAll))
        item(L10n.text("清除选择"), #selector(contextSelectNone), enabled: selectionActive)
        menu.addItem(.separator())
        item(clipboard.pendingRemoteText == nil ? L10n.text("允许此终端写入剪贴板") : L10n.text("允许并复制刚才的内容"), #selector(contextAllowClipboard))
        item(L10n.text("禁止此终端写入剪贴板"), #selector(contextDenyClipboard))
        return menu
    }
    @objc private func contextCopy() { copy(self) }
    @objc private func contextCommandCopy() { copySemanticCommand(output: false) }
    @objc private func contextOutputCopy() { copySemanticCommand(output: true) }
    @objc private func contextPaste() { paste(self) }
    @objc private func contextSelectAll() { selectAll() }
    @objc private func contextSelectNone() { selectNone() }
    @objc private func contextAllowClipboard() { clipboard.allowRemoteCopy() }
    @objc private func contextDenyClipboard() { clipboard.denyRemoteCopy() }
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
        clipboard.noteUserInteraction()
        if receiveAttachments(from: NSPasteboard.general) { return }
        if let text = NSPasteboard.general.string(forType: .string), text.contains("\n") || text.contains("\r") {
            let alert = NSAlert(); alert.messageText = L10n.text("粘贴多行内容？"); alert.informativeText = L10n.text("内容可能包含会立即执行的命令。\n\n") + String(text.prefix(700)); alert.addButton(withTitle: L10n.text("粘贴")); alert.addButton(withTitle: L10n.text("取消"))
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
    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { clipboard.noteUserInteraction(); onInputActivity?(); super.send(source: source, data: data) }
    override func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) { super.send(source: self, data: data) }
    func sendAttachmentReference(_ text: String) {
        let bracketed = getTerminal().bracketedPasteMode
        if bracketed { process.send(data: Array("\u{1b}[200~".utf8)[...]) }
        process.send(data: Array(text.utf8)[...])
        if bracketed { process.send(data: Array("\u{1b}[201~".utf8)[...]) }
    }
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("在浏览器中打开链接？"); alert.informativeText = url.absoluteString; alert.addButton(withTitle: L10n.text("打开")); alert.addButton(withTitle: L10n.text("取消"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }
}

private final class TerminalSecurityProxy: TerminalViewDelegate {
    weak var owner: SafeTerminalView?
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
        DispatchQueue.main.async { [weak owner] in
            guard let owner else { return }
            let interactive = NSApp.isActive && NSApp.keyWindow === owner.window && owner.window?.firstResponder === owner
            owner.clipboard.receive(content, interactive: interactive) {
                let alert = NSAlert(); alert.messageText = L10n.text("允许此终端写入 Mac 剪贴板？"); alert.informativeText = L10n.text("终端程序请求复制内容（例如 tmux 复制模式）。通过终端协议读取剪贴板的请求始终被拒绝。"); alert.addButton(withTitle: L10n.text("允许本终端写入")); alert.addButton(withTitle: L10n.text("拒绝"))
                return alert.runModal() == .alertFirstButtonReturn
            }
        }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: UUID
    let host: HostProfile?
    let tmuxID: String?
    let terminal = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
    @Published var title: String
    @Published private var stateKey = "待连接"
    var state: String { L10n.key(stateKey) }
    @Published var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var retryDeadline: Date?
    @Published private(set) var autoReconnectPaused = false
    @Published private(set) var lastConnectionError: String?
    @Published private(set) var automaticAttempt = 0
    @Published var dimensions = ""
    @Published private(set) var reportedDirectory: String?
    var directoryChanged: (() -> Void)?
    private(set) var connectionID = UUID()
    private(set) var inputGeneration: UInt64 = 0
    private var started = false
    private var disposed = false
    private var pendingReconnect = false
    private var childActive = false
    private var hadConnection = false
    private var connectedAt: Date?
    private var recoveryNeeded = false
    private var automaticAttemptInProgress = false
    private var automaticReconnectEnabled = true
    private var retryPolicy = SSHRetryPolicy()
    private var retryTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var networkActivity: NSObjectProtocol?
    private var closingLease: TerminalSession?
    private var events: [ConnectionEvent] = []
    private var lastEnvironmentRetry = Date.distantPast
    var recoverySubscription: AnyCancellable?
    var connectionConfigurationValid: () -> Bool = { true }
    private var probe = CancellationFlag()
    private var preparingTmuxMenu = false
    private let transport: SSHTransport
    var dockerAttachmentBinding: DockerAttachmentBinding?
    var isLocal: Bool { host == nil }
    var displayName: String { host?.name ?? L10n.text("此 Mac") }
    var subtitle: String { host?.subtitle ?? L10n.text("\(NSUserName()) · \(LocalShellConfiguration.userShell) · 登录 Shell") }
    var restartLabel: String { isLocal ? L10n.text("重新打开") : L10n.text("重连") }
    init(host: HostProfile? = nil, tmuxID: String? = nil, transport: SSHTransport, id: UUID = UUID()) {
        self.id = id; self.host = host; self.tmuxID = tmuxID; self.transport = transport
        title = tmuxID == nil ? (host?.name ?? L10n.text("此 Mac")) : "tmux · \(host?.name ?? L10n.text("此 Mac"))"
        super.init()
        stateKey = isLocal ? "待启动" : "待连接"
        terminal.processDelegate = self; terminal.optionAsMetaKey = true
        terminal.semanticCommandCopyAllowed = tmuxID == nil
        terminal.remoteSelectionContext = tmuxID != nil
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.getTerminal().changeScrollback(10000)
        terminal.onInputActivity = { [weak self] in self?.inputGeneration &+= 1 }
    }
    func start(automatic: Bool = false) {
        guard !started, !disposed, !childActive else { return }
        guard connectionConfigurationValid() else { stateKey = "主机配置已变化，请重新打开终端"; autoReconnectPaused = true; releaseNetworkActivity(); return }
        started = true; connecting = true; automaticAttemptInProgress = automatic
        stateKey = isLocal ? "正在启动…" : (automatic ? "正在自动重连…" : "正在验证连接…"); probe = CancellationFlag()
        retryTask?.cancel(); retryTask = nil; retryDeadline = nil
        if !isLocal && networkActivity == nil { networkActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Maintain requested SSH connection") }
        connectionID = UUID()
        let attemptID = connectionID
        reportedDirectory = nil
        terminal.clipboard.resetPermission()
        terminal.resetGraphicsInput()
        let transport = automatic ? SSHTransport(paths: transport.paths, askpass: transport.askpass, noninteractive: transport.noninteractive, silentAuthentication: true) : transport
        let host = host; let cancellation = probe
        record(automatic ? "automatic_probe" : "manual_probe")
        Task {
            do {
                guard !disposed, !cancellation.isCancelled, connectionID == attemptID else { return }
                if let host {
                    let tmux = tmuxID != nil
                    let graphicsCompatible = try await Task.detached {
                        _ = try transport.run(host, command: SSHTransport.connectionProbe, cancellation: cancellation, timeout: automatic ? 20 : 120).checked()
                        if tmux { try transport.requirePosixShell(host, cancellation: cancellation) }
                        return try transport.supportsPosixShell(host, cancellation: cancellation)
                    }.value
                    guard !disposed, !cancellation.isCancelled, connectionID == attemptID else { return }
                    guard connectionConfigurationValid() else { connecting = false; started = false; stateKey = "主机配置已变化，请重新打开终端"; releaseNetworkActivity(); return }
                    terminal.prepareProcessStart()
                    terminal.startProcess(executable: "/usr/bin/ssh", args: try transport.terminalArguments(for: host, tmuxSession: tmuxID, graphicsCompatible: graphicsCompatible), environment: transport.environment(for: host).map { "\($0.key)=\($0.value)" })
                } else {
                    let configuration = try LocalShellConfiguration()
                    var environment = configuration.environment
                    environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
                    terminal.prepareProcessStart()
                    if let tmuxID {
                        terminal.startProcess(executable: try TmuxService.localExecutable(), args: ["attach-session", "-t", tmuxID], environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: configuration.directory)
                    } else {
                        terminal.startProcess(executable: configuration.executable, environment: environment.map { "\($0.key)=\($0.value)" }, execName: configuration.executableName, currentDirectory: configuration.directory)
                    }
                }
                guard terminal.process.running else { throw WorkbenchError.message(L10n.text("无法启动终端进程，请重新打开终端。")) }
                childActive = true; connecting = false; connected = true; hadConnection = true; connectedAt = Date(); recoveryNeeded = false
                stateKey = isLocal ? "运行中" : "已连接"; lastConnectionError = nil
                record("process_started", processID: terminal.process.shellPid)
                if terminal.shouldRequestFocus { terminal.window?.makeFirstResponder(terminal) }
            } catch {
                guard !disposed, !cancellation.isCancelled, connectionID == attemptID else { return }
                connecting = false; started = false; connected = false; lastConnectionError = error.localizedDescription
                stateKey = isLocal ? "启动失败" : "连接失败"
                if !isLocal, hadConnection, SSHRetryPolicy.permitsRetry(diagnostic: error.localizedDescription) {
                    recoveryNeeded = true; record("network_probe_failed"); scheduleAutomaticReconnect()
                } else {
                    autoReconnectPaused = automatic; record(automatic ? "automatic_probe_needs_attention" : "manual_probe_failed"); releaseNetworkActivity()
                    if automatic { stateKey = "自动重连已暂停，请手动验证" }
                    else {
                        let safe = error.localizedDescription.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }.map(String.init).joined()
                        terminal.dataReceived(slice: Array(("\r\n" + safe.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n").utf8)[...])
                    }
                }
            }
        }
    }
    func reconnect() {
        guard !disposed else { return }
        probe.cancel(); retryTask?.cancel(); retryTask = nil; retryDeadline = nil
        autoReconnectPaused = false; recoveryNeeded = false; retryPolicy.reset(); automaticAttempt = 0; connecting = false
        record("manual_reconnect_requested")
        if childActive { pendingReconnect = true; connected = false; stateKey = "正在关闭旧连接…"; stopOwnedProcess() }
        else { started = false; start() }
    }
    func requestManualReconnect() {
        guard !pendingReconnect else { return }
        if childActive, tmuxID == nil, !confirm(L10n.text("重新连接当前终端？"), L10n.text("当前普通 Shell 的前台任务可能被结束；不会重放命令。tmux 只重新附着原会话。")) { return }
        reconnect()
    }
    func setAutomaticReconnect(_ enabled: Bool) {
        automaticReconnectEnabled = enabled
        if !enabled { pauseAutomaticReconnect() }
        else { autoReconnectPaused = false; if recoveryNeeded { scheduleAutomaticReconnect(immediate: true) } }
    }
    func pauseAutomaticReconnect() {
        autoReconnectPaused = true; retryTask?.cancel(); retryTask = nil; retryDeadline = nil
        if connecting && automaticAttemptInProgress { probe.cancel(); connecting = false; started = false; connectionID = UUID() }
        if !connected && (!connecting || automaticAttemptInProgress) { stateKey = "自动重连已暂停"; releaseNetworkActivity() }
        record("automatic_reconnect_paused")
    }
    func recoveryEnvironmentChanged(_ event: String) {
        guard !disposed, !isLocal else { return }
        record(event)
        guard event != "network_path_changed", recoveryNeeded, !connecting, !childActive,
              Date().timeIntervalSince(lastEnvironmentRetry) >= 2 else { return }
        lastEnvironmentRetry = Date(); scheduleAutomaticReconnect(immediate: true)
    }
    private func scheduleAutomaticReconnect(stableDuration: TimeInterval = 0, immediate: Bool = false) {
        guard !disposed, !isLocal, hadConnection, recoveryNeeded, automaticReconnectEnabled, !autoReconnectPaused, !childActive, !connecting else { releaseNetworkActivity(); return }
        guard connectionConfigurationValid() else { autoReconnectPaused = true; stateKey = "主机配置已变化，请重新打开终端"; releaseNetworkActivity(); return }
        retryTask?.cancel()
        let delay = immediate ? 0.2 : retryPolicy.nextDelay(stableDuration: stableDuration) + Double.random(in: 0...0.4)
        automaticAttempt = max(1, retryPolicy.failures); retryDeadline = Date().addingTimeInterval(delay); stateKey = "等待自动重连"
        record("automatic_reconnect_scheduled")
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !disposed, recoveryNeeded, automaticReconnectEnabled, !autoReconnectPaused, !childActive, !connecting else { return }
            retryTask = nil; retryDeadline = nil; started = false; start(automatic: true)
        }
    }
    private func stopOwnedProcess() {
        guard childActive, terminal.process.shellPid > 0 else { return }
        closingLease = self
        let processID = terminal.process.shellPid; let originalConnection = connectionID
        if !terminal.observedProcessExit && processID > 0 { _ = Darwin.kill(processID, SIGTERM) }
        terminationTask?.cancel()
        terminationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, childActive, connectionID == originalConnection, !terminal.observedProcessExit, terminal.process.shellPid == processID else { return }
            record("owned_process_force_stop", processID: processID); _ = Darwin.kill(processID, SIGKILL)
        }
    }
    private func releaseNetworkActivity() { if let networkActivity { ProcessInfo.processInfo.endActivity(networkActivity); self.networkActivity = nil } }
    private func record(_ event: String, processID: Int32? = nil, waitStatus: Int32? = nil) {
        events.append(ConnectionEvent(event: event, processID: processID, waitStatus: waitStatus)); events = Array(events.suffix(60))
    }
    func copyConnectionDiagnostics() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(events), let text = String(data: data, encoding: .utf8) { terminal.clipboard.write(text) }
    }
    func enableTmuxMenuIfNeeded() {
        guard let tmuxID, connected, !preparingTmuxMenu else { return }
        preparingTmuxMenu = true
        let originalConnection = connectionID; let service = TmuxService(transport: transport, host: host)
        Task {
            defer { preparingTmuxMenu = false }
            do {
                let enabled = try await Task.detached { try service.mouseEnabled(session: tmuxID) }.value
                guard connected, connectionID == originalConnection, terminal.prefersTmuxMenu?() == true else { return }
                if !enabled {
                    guard confirm(L10n.text("为此 tmux 会话启用鼠标？"), L10n.text("只调整当前会话，不修改全局配置文件；共享这个会话的其他客户端也会受影响。启用后请再次右键。")) else { return }
                    guard connected, connectionID == originalConnection, terminal.prefersTmuxMenu?() == true else { return }
                    try await Task.detached { try service.enableMouse(session: tmuxID) }.value
                }
            } catch { AppStore.shared.errorMessage = error.localizedDescription }
        }
    }
    func close() {
        guard !disposed else { return }; disposed = true; pendingReconnect = false; recoveryNeeded = false
        probe.cancel(); retryTask?.cancel(); retryTask = nil; retryDeadline = nil; recoverySubscription?.cancel()
        connected = false; connecting = false; stateKey = isLocal ? "已结束" : "已断开"; record("closed_by_user")
        if childActive { stopOwnedProcess() }; releaseNetworkActivity()
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let value = "\(newCols) × \(newRows)"
            if dimensions != value { terminal.commandCapture.reset() }
            dimensions = value
        }
    }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) { DispatchQueue.main.async { [weak self] in if !title.isEmpty { self?.title = String(title.prefix(100)) } } }
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) { DispatchQueue.main.async { [weak self] in if !title.isEmpty { self?.title = String(title.prefix(100)) } } }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let names: Set<String> = host.map { [$0.address] } ?? Set(["localhost", "127.0.0.1", "::1", Host.current().name, Host.current().localizedName].compactMap { $0 })
            reportedDirectory = tmuxID == nil ? TerminalDirectory.path(from: directory, allowedHosts: names) : nil
            directoryChanged?()
        }
    }
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, childActive else { return }
            childActive = false; connected = false; connecting = false; terminationTask?.cancel(); terminationTask = nil
            defer { closingLease = nil }
            record("process_exited", processID: terminal.process.shellPid, waitStatus: exitCode)
            guard !disposed else { releaseNetworkActivity(); return }
            if pendingReconnect { pendingReconnect = false; started = false; start(); return }
            let result = TerminalProcessExit(waitStatus: exitCode)
            stateKey = isLocal ? (result.code == 0 ? "已结束" : "进程已退出") : (result.shouldRecoverSSH ? "连接已中断" : "远端会话已结束")
            recoveryNeeded = !isLocal && result.shouldRecoverSSH
            if recoveryNeeded { scheduleAutomaticReconnect(stableDuration: connectedAt.map { Date().timeIntervalSince($0) } ?? 0) }
            else { record("remote_session_ended"); releaseNetworkActivity() }
        }
    }
    deinit {
        retryTask?.cancel(); terminationTask?.cancel(); recoverySubscription?.cancel()
        if let networkActivity { ProcessInfo.processInfo.endActivity(networkActivity) }
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
            if page != oldValue { focusGeneration &+= 1 }
            if page == .files, oldValue != .files, fileSource == nil { followCurrentTerminalFiles() }
            if page == .terminal { alignTerminalWithHost() }
        }
    }
    @Published var sessions: [TerminalSession] = []
    @Published var layout = TerminalLayout() {
        didSet { if layout.focused != oldValue.focused { focusGeneration &+= 1 }; rememberWorkspace() }
    }
    let tabDragScope = UUID()
    @Published var browsingLocalFiles = false
    @Published var showTransferTray = false
    @Published var hostSearch = ""
    @Published var filePanes: [FilePane] = []
    @Published var fileLayout = TerminalLayout()
    var fileSource: FileBrowserSource? {
        get { focusedFilePane?.source }
        set {
            if page == .files, let window = currentFileBrowser?.tableView?.window, window.isKeyWindow,
               window.attachedSheet == nil, NSApp.modalWindow == nil { window.makeFirstResponder(nil) }
            objectWillChange.send()
            if let pane = focusedFilePane { pane.source = newValue }
            else if let source = newValue {
                let pane = FilePane(source: source); filePanes.append(pane); fileLayout.select(pane.id)
            }
            currentFileBrowser?.focusRequest &+= 1
        }
    }
    @Published var attachmentDraft: TerminalAttachmentDraft?
    @Published var sidebarCollapsed = false
    @Published var showTerminalSearch = false
    @Published var showCommandSnippets = false
    @Published var screenSharingHost: HostProfile?
    @Published var webServiceHost: HostProfile?
    @Published var followTerminalDirectory = false
    var savedWorkspaceID = UUID()
    var restoringWorkspace = false
    @Published private var fileTerminalOrder: [UUID] = []
    var orderedFileSessions: [TerminalSession] { fileTerminalOrder.compactMap { identifier in sessions.first { $0.id == identifier } } }
    func toggleSidebar() {
        sidebarCollapsed.toggle()
        if !store.isTestWorkspace { UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed") }
    }
    func reorderFileTab(_ identifier: UUID, onto target: UUID) {
        guard identifier != target, let source = fileTerminalOrder.firstIndex(of: identifier), let destination = fileTerminalOrder.firstIndex(of: target) else { return }
        fileTerminalOrder.remove(at: source); fileTerminalOrder.insert(identifier, at: destination)
    }
    private var focusGeneration: UInt64 = 0
    private var terminalNumbers: [UUID: Int] = [:]
    private var hostTerminalCounts: [UUID?: Int] = [:]
    let store: AppStore
    init(store: AppStore) { self.store = store; selectedHostID = store.hosts.first?.id; sidebarCollapsed = !store.isTestWorkspace && UserDefaults.standard.bool(forKey: "sidebarCollapsed") }
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
        guard fileSourceAvailable else { return L10n.text("文件来源已失效") }
        if let identifier = fileSource?.terminalID, let session = sessions.first(where: { $0.id == identifier }) { return sessionLabel(session) }
        return fileHost.map { L10n.text("\($0.name) · 主机文件") } ?? L10n.text("此 Mac · 本地文件")
    }
    var currentFileBrowser: FileModel? {
        guard fileSourceAvailable, let source = fileSource else { return nil }
        return fileBrowser(for: source, host: fileHost)
    }
    private func fileBrowser(for source: FileBrowserSource, host: HostProfile?) -> FileModel {
        if let pane = focusedFilePane { return pane.browser(for: source, host: host, store: store, showPreview: filePanes.count == 1) }
        let pane = FilePane(source: source)
        filePanes.append(pane); fileLayout.select(pane.id)
        return pane.browser(for: source, host: host, store: store, showPreview: filePanes.count == 1)
    }
    func sessionLabel(_ session: TerminalSession) -> String {
        "\(session.displayName) · \(session.isLocal ? L10n.text("本机") : (session.tmuxID == nil ? L10n.text("终端") : "tmux")) \(terminalNumbers[session.id] ?? 1)"
    }
    private func register(_ session: TerminalSession) {
        let next = (hostTerminalCounts[session.host?.id] ?? 0) + 1
        hostTerminalCounts[session.host?.id] = next; terminalNumbers[session.id] = next
        sessions.append(session)
        session.terminal.onContextFocus = { [weak self, weak session] in
            guard let self, let session, layout.selectedTab?.terminals.contains(session.id) == true else { return }
            if selectedTerminalID != session.id { selectTerminal(session) }
        }
        session.terminal.prefersTmuxMenu = { [weak self, weak session] in self?.store.useTmuxContextMenu == true && session?.tmuxID != nil && session?.connected == true }
        session.terminal.prepareTmuxMenu = { [weak session] in session?.enableTmuxMenuIfNeeded() }
        session.setAutomaticReconnect(store.automaticallyReconnectSSH)
        let configuredHost = session.host
        session.connectionConfigurationValid = { [weak self] in
            guard let self else { return false }
            guard let configuredHost else { return true }
            return store.hosts.contains { $0.id == configuredHost.id && $0.connectionKey == configuredHost.connectionKey }
        }
        session.recoverySubscription = store.connectionRecoveryEvents.events.sink { [weak session] event in session?.recoveryEnvironmentChanged(event) }
        session.terminal.commandCapture.completed = { [weak self, weak session] elapsed, status in
            guard let self, let session else { return }
            let detail = status.map { L10n.text("Shell 报告退出码：") + String($0) } ?? L10n.text("Shell 报告命令结束，未提供退出码。")
            let background = !NSApp.isActive || page != .terminal || selectedTerminalID != session.id || session.terminal.window?.isKeyWindow != true
            store.notifyTaskCompletion(title: session.displayName, detail: detail, elapsed: elapsed, background: background)
        }
        session.directoryChanged = { [weak self, weak session] in
            guard let self, let session else { return }
            objectWillChange.send()
            if followTerminalDirectory, fileSource?.terminalID == session.id { locateTerminalDirectory(session) }
        }
        fileTerminalOrder.append(session.id)
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
    func rememberWorkspace() {
        guard !restoringWorkspace else { return }
        let identifiers = Set(layout.tabs.flatMap(\.terminals))
        let saved = sessions.filter { identifiers.contains($0.id) }.map { SavedTerminal(id: $0.id, hostID: $0.host?.id, connectionKey: $0.host?.connectionKey, tmuxID: $0.tmuxID) }
        store.workspaceTools.workspaces.removeAll { $0.id == savedWorkspaceID }
        if !saved.isEmpty {
            let names = sessions.filter { identifiers.contains($0.id) }.map(\.displayName)
            let title = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ")
            let snapshot = WorkspaceSnapshot(id: savedWorkspaceID, title: title, terminals: saved, layout: layout)
            if (try? snapshot.validate()) != nil { store.workspaceTools.workspaces.insert(snapshot, at: 0) }
        }
        store.workspaceTools.workspaces = Array(store.workspaceTools.workspaces.prefix(10))
        store.saveWorkspaceTools()
    }
    func restoreWorkspace(_ snapshot: WorkspaceSnapshot) {
        guard sessions.isEmpty else { store.errorMessage = L10n.text("请在空窗口恢复工作区，现有终端不会被替换。"); return }
        do {
            try snapshot.validate()
            var restoredLayout = snapshot.layout
            var skipped = 0
            restoringWorkspace = true
            defer { restoringWorkspace = false }
            for saved in snapshot.terminals {
                let profile = saved.hostID.flatMap { identifier in store.hosts.first { $0.id == identifier && $0.connectionKey == saved.connectionKey } }
                if saved.hostID != nil && profile == nil { restoredLayout.close(saved.id); skipped += 1; continue }
                register(TerminalSession(host: profile, tmuxID: saved.tmuxID, transport: store.transport, id: saved.id))
            }
            layout = restoredLayout
            selectedHostID = selectedTerminal?.host?.id; page = .terminal
            if skipped > 0 { store.errorMessage = L10n.text("已跳过删除或连接配置已变化的主机；未向它们发起连接。") }
        } catch { store.errorMessage = error.localizedDescription }
    }
    func locateTerminalDirectory(_ session: TerminalSession) {
        guard session.connected, let directory = session.reportedDirectory else { return }
        let browser = fileBrowser(for: .terminal(session.id), host: session.host)
        if browser.path != directory { browser.load(directory) }
    }
    func openTerminalDirectory() {
        guard let session = selectedTerminal, session.reportedDirectory != nil else {
            store.errorMessage = L10n.text("终端尚未报告可信目录。需要 OSC 7 Shell 集成；tmux 或主机不匹配时请手动浏览。"); return
        }
        browseFiles(.terminal(session.id)); locateTerminalDirectory(session)
    }
    func attachmentIdentity(_ session: TerminalSession) -> AttachmentDeliveryIdentity {
        let window = session.terminal.window
        return AttachmentDeliveryIdentity(sessionID: session.id, connectionID: session.connectionID, focusGeneration: focusGeneration, inputGeneration: session.inputGeneration,
                                          windowNumber: window?.windowNumber, applicationActive: NSApp.isActive)
    }
    func canAutomaticallyInsert(_ draft: TerminalAttachmentDraft) -> Bool {
        let current = attachmentIdentity(draft.session)
        let keyWindow = NSApp.keyWindow
        return store.automaticallyInsertAttachments(for: draft.session.host)
            && current.allowsAutomaticInsertion(from: draft.identity) && keyWindow === draft.session.terminal.window
            && NSApp.modalWindow == nil && keyWindow?.attachedSheet == nil && keyWindow?.firstResponder === draft.session.terminal
            && selectedTerminalID == draft.session.id && page == .terminal
    }
    func automaticInsertionBlocker(_ draft: TerminalAttachmentDraft) -> String? {
        let current = attachmentIdentity(draft.session)
        if !store.automaticallyInsertAttachments(for: draft.session.host) { return L10n.text("自动插入已关闭，请手动插入。") }
        if !draft.session.connectionConfigurationValid() { return L10n.text("主机配置已变化，请重新确认附件目标。") }
        if !draft.session.connected || current.connectionID != draft.identity.connectionID { return L10n.text("连接已变化，请确认原终端后手动插入。") }
        if current.inputGeneration != draft.identity.inputGeneration { return L10n.text("上传期间有新的终端输入，请确认输入位置后手动插入。") }
        if current.focusGeneration != draft.identity.focusGeneration || selectedTerminalID != draft.session.id || page != .terminal { return L10n.text("上传期间切换了目标，请回原终端确认后手动插入。") }
        if !current.preservesAutomaticTarget(from: draft.identity) { return L10n.text("原窗口已变化，请手动确认插入目标。") }
        return nil
    }
    func restoreTransientAttachmentFocus(_ draft: TerminalAttachmentDraft) {
        guard automaticInsertionBlocker(draft) == nil, NSApp.isActive, NSApp.modalWindow == nil,
              let window = draft.session.terminal.window, window === NSApp.keyWindow, window.attachedSheet == nil,
              window.firstResponder == nil || window.firstResponder === window else { return }
        window.makeFirstResponder(draft.session.terminal)
    }
    func requestAttachments(session: TerminalSession, payload: TerminalAttachmentPayload) {
        guard session.connected, sessions.contains(where: { $0.id == session.id }), attachmentDraft?.busy != true else {
            if let temporary = payload.temporaryDirectory { try? FileManager.default.removeItem(at: temporary) }
            store.errorMessage = L10n.text("终端未连接或已有附件任务，请先完成当前操作。"); return
        }
        attachmentDraft?.dispose(); attachmentDraft = nil
        selectTerminal(session); page = .terminal
        attachmentDraft = TerminalAttachmentDraft(session: session, payload: payload, workspace: self)
    }
    func chooseAttachments() {
        guard let session = selectedTerminal, session.connected else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.prompt = L10n.text("发送到此终端")
        if panel.runModal() == .OK { requestAttachments(session: session, payload: TerminalAttachmentPayload(files: panel.urls, temporaryDirectory: nil)) }
    }
    func chooseTab(_ session: TerminalSession) {
        if page == .files { if fileSource != .terminal(session.id) { focusGeneration &+= 1 }; fileSource = .terminal(session.id) }
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
        layout.select(session.id); browsingLocalFiles = session.isLocal; selectedHostID = session.host?.id
        fileSource = .terminal(session.id)
        session.terminal.window?.makeFirstResponder(session.terminal)
    }
    func chooseTerminalTab(_ identifier: UUID) {
        guard let tab = layout.tabs.first(where: { $0.id == identifier }), let session = sessions.first(where: { $0.id == tab.focused }) else { return }
        selectTerminal(session)
    }
    @discardableResult func reorderTab(payload: String, onto target: UUID?) -> Bool {
        let parts = payload.split(separator: ":")
        guard parts.count == 2, UUID(uuidString: String(parts[0])) == tabDragScope, let identifier = UUID(uuidString: String(parts[1])),
              let sourceIndex = layout.tabs.firstIndex(where: { $0.id == identifier }), identifier != target else { return false }
        var before = target
        if let target, let targetIndex = layout.tabs.firstIndex(where: { $0.id == target }), sourceIndex < targetIndex {
            before = layout.tabs.dropFirst(targetIndex + 1).first?.id
        }
        layout.moveTab(identifier, before: before)
        return true
    }
    func focusNextPane(backward: Bool = false) {
        if page == .files { fileLayout.focusNext(backward: backward); currentFileBrowser?.focusRequest &+= 1; return }
        layout.focusNext(backward: backward)
        if let session = selectedTerminal { selectTerminal(session) }
    }
    func selectNextTab(backward: Bool = false) {
        layout.selectNextTab(backward: backward)
        if let session = selectedTerminal { selectTerminal(session) }
    }
    func togglePaneZoom() { if page == .files { fileLayout.toggleZoom() } else { layout.toggleZoom() } }
    func confirmClosePane(_ session: TerminalSession) {
        let detail = session.tmuxID != nil ? L10n.text("只分离此终端，tmux 会话继续运行。") : L10n.text("当前 Shell 和前台任务可能随连接关闭。")
        if session.connected && !confirm(L10n.text("关闭此分栏？"), detail) { return }
        close(session)
    }
    func closeTab(_ identifier: UUID) {
        guard let tab = layout.tabs.first(where: { $0.id == identifier }) else { return }
        let closing = sessions.filter { tab.terminals.contains($0.id) }
        if closing.contains(where: \.connected) && !confirm(L10n.text("关闭此标签的 \(closing.count) 个终端？"), L10n.text("普通 Shell 和前台任务可能结束；tmux 只分离，不结束远端会话。其他标签不受影响。")) { return }
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
        objectWillChange.send()
        for pane in filePanes {
            pane.remove(source)
            if pane.source == source { pane.source = session.host.map { .host($0.id) } ?? .local }
        }
        terminalNumbers.removeValue(forKey: session.id)
        session.close(); sessions.removeAll { $0.id == session.id }
        fileTerminalOrder.removeAll { $0 == session.id }
        layout.close(session.id, fallback: sessions.last(where: { $0.host?.id == selectedHostID })?.id ?? sessions.last?.id)
        if let selectedTerminal { browsingLocalFiles = selectedTerminal.isLocal; selectedHostID = selectedTerminal.host?.id }
    }
}

enum WorkspacePage: String, CaseIterable {
    case terminal = "终端", tmux = "tmux 会话", files = "文件", transfers = "传输", tunnels = "隧道", monitor = "监控"
    var title: String { L10n.key(rawValue) }
    var symbol: String {
        switch self { case .terminal: return "terminal"; case .tmux: return "square.stack.3d.up"; case .files: return "folder"; case .transfers: return "arrow.left.arrow.right"; case .tunnels: return "point.3.connected.trianglepath.dotted"; case .monitor: return "waveform.path.ecg" }
    }
}
