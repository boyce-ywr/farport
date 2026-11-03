import AppKit
import Security
import WorkbenchCore
import OpenSSHBackend
import RemoteDesktop

/// 远程桌面口令：Farport 自己的钥匙串条目，按“主机 + 桌面目标 + 用户名”区分；不读取系统屏幕共享的条目，不复用 SSH 凭据。
enum RemoteDesktopCredentialStore {
    static let service = "local.sshworkbench.desktop"
    static func account(host: UUID, endpoint: ScreenSharingEndpoint, username: String) -> String { "\(host.uuidString)|\(endpoint.forwardingTarget)|\(username)" }
    static func load(host: UUID, endpoint: ScreenSharingEndpoint, username: String) -> String? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(host: host, endpoint: endpoint, username: username), kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ password: String, host: UUID, endpoint: ScreenSharingEndpoint, username: String) {
        delete(host: host, endpoint: endpoint, username: username)
        SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrLabel as String: "Farport 远程桌面",
                    kSecAttrAccount as String: account(host: host, endpoint: endpoint, username: username), kSecValueData as String: Data(password.utf8),
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked] as CFDictionary, nil)
    }
    static func delete(host: UUID, endpoint: ScreenSharingEndpoint, username: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account(host: host, endpoint: endpoint, username: username)] as CFDictionary)
    }
    /// 删除主机时一并清除其全部桌面口令。
    static func deleteAll(host: UUID) {
        var results: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        guard SecItemCopyMatching(query as CFDictionary, &results) == errSecSuccess, let records = results as? [[String: Any]] else { return }
        for record in records {
            guard let account = record[kSecAttrAccount as String] as? String, account.hasPrefix(host.uuidString + "|") else { continue }
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        }
    }
}

/// 每台主机记住的桌面连接方式（不含口令）。
struct RemoteDesktopPreferences: Codable, Equatable {
    var target = "127.0.0.1"
    var port = 5900
    var throughSSH = true
    var username = ""
    static func load(_ host: UUID) -> RemoteDesktopPreferences? {
        UserDefaults.standard.data(forKey: "remoteDesktop." + host.uuidString).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    func save(_ host: UUID) { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "remoteDesktop." + host.uuidString) } }
}

private final class CredentialRequest: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var result: RFBCredentials?
    private var answered = false
    private let lock = NSLock()
    func answer(_ value: RFBCredentials?) {
        let first: Bool = lock.withLock { defer { answered = true }; return !answered }
        guard first else { return }
        result = value; semaphore.signal()
    }
}

@MainActor
final class RemoteDesktopSession: ObservableObject, Identifiable {
    enum Phase: Equatable { case connecting, credentials(RFBCredentialKind), connected, failed(String), closed }
    struct Status: Equatable { var fps = 0; var kilobytesPerSecond = 0; var latency: TimeInterval?; var encoding = "" }

    let id = UUID()
    let host: HostProfile
    let endpoint: ScreenSharingEndpoint
    let throughSSH: Bool
    private let transport: SSHTransport
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var info: RFBServerInfo?
    @Published private(set) var status = Status()
    @Published private(set) var size = CGSize.zero
    @Published private(set) var cursor: NSCursor?
    @Published private(set) var utf8Clipboard = false
    @Published var notice: String?
    @Published var quality: RFBQuality = .balanced { didSet { if quality != oldValue { client?.setQuality(quality) } } }
    @Published var commandMapping: RFBKeyboard.CommandMapping = .native
    @Published var clipboardEnabled = true
    @Published var poppedOut = false { didSet { if poppedOut != oldValue { onLayoutChange?() } } }
    var onLayoutChange: (() -> Void)?
    @Published var savedUsername: String
    /// 登录框的上一次错误（认证失败后重新询问时显示）。
    @Published private(set) var credentialError: String?
    private(set) var client: RFBClient?
    private var process: Process?
    private var errorPipe: Pipe?
    private var pipes: [Pipe] = []
    private var sshErrors = ""
    /// 每次连接递增；旧连接迟到的回调（如重连时旧客户端的关闭事件）按代数丢弃。
    private var generation = 0
    private var pendingCredential: CredentialRequest?
    private var usedSavedPassword: (username: String, password: String)?
    private var skipSavedPassword = false
    private var saveRequested: (username: String, password: String)?
    private var statsTimer: Timer?
    private var lastCounters: (UInt64, UInt64) = (0, 0)
    private var lastFrames: UInt64 = 0
    private var pendingRemoteClipboard: String?
    private var lastLocalChangeCount = NSPasteboard.general.changeCount
    private var ownPasteboardChange: Int?
    private var visible = true
    private var noticeTask: Task<Void, Never>?
    lazy var view: RemoteDesktopNSView = RemoteDesktopNSView(session: self)
    var onClose: (() -> Void)?
    var title: String { host.name + " · " + L10n.text("桌面") }

    init(host: HostProfile, endpoint: ScreenSharingEndpoint, throughSSH: Bool, transport: SSHTransport) {
        self.host = host; self.endpoint = endpoint; self.throughSSH = throughSSH; self.transport = transport
        savedUsername = RemoteDesktopPreferences.load(host.id)?.username ?? ""
    }

    // MARK: 连接

    func connect() {
        disconnect(keepPhase: true)
        generation += 1
        phase = .connecting; info = nil; credentialError = nil
        let host = host, endpoint = endpoint, transport = transport, throughSSH = throughSSH, current = generation
        Task.detached { [weak self] in
            do {
                let stream: RFBStream
                var process: Process?
                var errors: Pipe?
                var pipes: [Pipe] = []
                if throughSSH {
                    let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    child.arguments = try transport.screenSharingArguments(for: host, endpoint: endpoint)
                    child.environment = transport.environment(for: host)
                    let input = Pipe(), output = Pipe(), error = Pipe()
                    child.standardInput = input; child.standardOutput = output; child.standardError = error
                    try child.run()
                    process = child; errors = error; pipes = [input, output, error]
                    stream = RFBStream(readDescriptor: output.fileHandleForReading.fileDescriptor, writeDescriptor: input.fileHandleForWriting.fileDescriptor, ownsDescriptors: false)
                } else {
                    stream = try RFBStream.connect(host: endpoint.host, port: endpoint.port)
                }
                await self?.attach(stream: stream, process: process, errors: errors, pipes: pipes, generation: current)
            } catch {
                await self?.fail(error.localizedDescription, generation: current)
            }
        }
    }
    private func attach(stream: RFBStream, process: Process?, errors: Pipe?, pipes: [Pipe], generation current: Int) {
        guard phase == .connecting, current == generation else { stream.close(); process?.terminate(); return }
        self.process = process; errorPipe = errors; self.pipes = pipes; sshErrors = ""
        errors?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { if let self { self.sshErrors = String((self.sshErrors + text).suffix(2000)) } }
        }
        let client = RFBClient(stream: stream, quality: quality)
        self.client = client
        client.events.credentials = { [weak self] kind in
            let request = CredentialRequest()
            DispatchQueue.main.async { guard let self, self.generation == current else { request.answer(nil); return }; self.requestCredentials(kind, request) }
            request.semaphore.wait()
            return request.result
        }
        client.events.connected = { [weak self] info in DispatchQueue.main.async { if self?.generation == current { self?.connected(info) } } }
        client.events.resized = { [weak self] width, height in DispatchQueue.main.async { guard self?.generation == current else { return }; self?.size = CGSize(width: width, height: height); self?.view.framebufferChanged() } }
        client.events.updated = { [weak self] in DispatchQueue.main.async { self?.view.framebufferChanged() } }
        client.events.cursor = { [weak self] rgba, width, height, hotX, hotY in
            DispatchQueue.main.async { guard self?.generation == current else { return }; self?.updateCursor(rgba, width, height, hotX, hotY) }
        }
        client.events.clipboard = { [weak self] text in DispatchQueue.main.async { guard self?.generation == current else { return }; self?.received(clipboard: text) } }
        client.events.extendedClipboard = { [weak self] value in DispatchQueue.main.async { if self?.generation == current { self?.utf8Clipboard = value } } }
        client.events.bell = { DispatchQueue.main.async { NSSound.beep() } }
        client.events.closed = { [weak self] error in DispatchQueue.main.async { if self?.generation == current { self?.closed(error) } } }
        client.start()
    }

    private func requestCredentials(_ kind: RFBCredentialKind, _ request: CredentialRequest) {
        guard client != nil else { request.answer(nil); return }
        let username = kind == .usernameAndPassword ? savedUsername : ""
        if !skipSavedPassword, kind == .password || !username.isEmpty,
           let password = RemoteDesktopCredentialStore.load(host: host.id, endpoint: endpoint, username: username) {
            usedSavedPassword = (username, password)
            request.answer(RFBCredentials(username: username, password: password)); return
        }
        pendingCredential = request
        phase = .credentials(kind)
    }

    /// 登录框提交；save 为 true 时连接成功后才写入钥匙串。
    func submitCredentials(username: String, password: String, save: Bool) {
        guard let request = pendingCredential, case .credentials(let kind) = phase else { return }
        pendingCredential = nil
        let user = kind == .usernameAndPassword ? username.trimmingCharacters(in: .whitespaces) : ""
        if kind == .usernameAndPassword { savedUsername = user; rememberPreferences() }
        saveRequested = save ? (user, password) : nil
        usedSavedPassword = nil
        phase = .connecting
        request.answer(RFBCredentials(username: user, password: password))
    }
    func cancelCredentials() {
        pendingCredential?.answer(nil); pendingCredential = nil
        close()
    }

    private func connected(_ value: RFBServerInfo) {
        info = value; size = CGSize(width: value.width, height: value.height); phase = .connected
        commandMapping = value.isMacOS ? .native : .control
        if let saved = saveRequested { RemoteDesktopCredentialStore.save(saved.password, host: host.id, endpoint: endpoint, username: saved.username) }
        saveRequested = nil; skipSavedPassword = false; credentialError = nil
        lastCounters = (0, 0); lastFrames = 0
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateStatus() } }
        client?.setPaused(!visible)
        view.framebufferChanged()
        if view.window?.firstResponder === view { focusChanged(true) }
    }

    private func closed(_ error: Error?) {
        statsTimer?.invalidate(); statsTimer = nil
        pendingCredential?.answer(nil); pendingCredential = nil
        let processError = sshErrors.trimmingCharacters(in: .whitespacesAndNewlines)
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate(); process = nil; errorPipe = nil; pipes = []; client = nil
        view.releaseInput()
        guard phase != .closed else { return }
        guard let error else { phase = .closed; return }
        if case .authenticationFailed = error as? RFBError {
            // 认证失败：不自动重试；若用的是已保存口令则删除，下次重新询问。
            if let used = usedSavedPassword { RemoteDesktopCredentialStore.delete(host: host.id, endpoint: endpoint, username: used.username) }
            usedSavedPassword = nil; saveRequested = nil; skipSavedPassword = true
            credentialError = error.localizedDescription
            phase = .failed(error.localizedDescription); return
        }
        if case .cancelled = error as? RFBError { phase = .closed; return }
        var message = error.localizedDescription
        if throughSSH, !processError.isEmpty, (error as? RFBError) == .closed || phase == .connecting {
            message = L10n.text("SSH 桌面通道失败：") + processError.split(separator: "\n").suffix(3).joined(separator: " ")
        }
        phase = .failed(message)
    }

    private func fail(_ message: String, generation current: Int) {
        guard phase == .connecting, current == generation else { return }
        phase = .failed(message)
    }

    func disconnect(keepPhase: Bool = false) {
        pendingCredential?.answer(nil); pendingCredential = nil
        if !keepPhase { phase = .closed }
        client?.stop(); client = nil
        process?.terminate(); process = nil
        statsTimer?.invalidate(); statsTimer = nil
    }
    func close() { disconnect(); onClose?() }

    func rememberPreferences() {
        RemoteDesktopPreferences(target: endpoint.host, port: endpoint.port, throughSSH: throughSSH, username: savedUsername).save(host.id)
    }

    // MARK: 状态

    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        client?.setPaused(!value)
        if value { view.framebufferChanged() }
    }

    private func updateStatus() {
        guard let client else { return }
        let counters = client.counters, statistics = client.statistics
        let received = counters.received &- lastCounters.0
        status = Status(fps: Int(statistics.frames &- lastFrames), kilobytesPerSecond: Int(received / 1024), latency: statistics.latency, encoding: client.lastEncoding)
        lastCounters = (counters.received, counters.sent); lastFrames = statistics.frames
        if visible { client.ping() }
    }

    func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in try? await Task.sleep(for: .seconds(4)); self?.notice = nil }
    }

    private func updateCursor(_ rgba: [UInt8], _ width: Int, _ height: Int, _ hotX: Int, _ hotY: Int) {
        guard width > 0, height > 0, let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: width * 4, bitsPerPixel: 32),
              let data = representation.bitmapData else { cursor = nil; view.window?.invalidateCursorRects(for: view); return }
        rgba.withUnsafeBufferPointer { _ = memcpy(data, $0.baseAddress!, rgba.count) }
        // 远端帧缓冲按像素计，光标按当前显示比例缩放到点。
        let scale = view.displayScale
        let image = NSImage(size: NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale))
        image.addRepresentation(representation)
        cursor = NSCursor(image: image, hotSpot: NSPoint(x: CGFloat(hotX) * scale, y: CGFloat(hotY) * scale))
        view.window?.invalidateCursorRects(for: view)
    }

    // MARK: 剪贴板（仅在桌面获得焦点时同步）

    private func received(clipboard text: String) {
        guard clipboardEnabled, !text.isEmpty, text.utf8.count <= 1024 * 1024 else { return }
        if view.hasKeyboardFocus { writePasteboard(text) } else { pendingRemoteClipboard = text }
    }
    private func writePasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        ownPasteboardChange = pasteboard.changeCount; lastLocalChangeCount = pasteboard.changeCount
    }
    /// 桌面获得或失去键盘焦点。获得时先补写远端暂存的内容，再把本地新复制的文本发给远端。
    func focusChanged(_ focused: Bool) {
        guard focused, clipboardEnabled, let client, phase == .connected else { return }
        if let pending = pendingRemoteClipboard { pendingRemoteClipboard = nil; writePasteboard(pending); return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastLocalChangeCount else { return }
        lastLocalChangeCount = pasteboard.changeCount
        guard pasteboard.changeCount != ownPasteboardChange, let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        guard text.utf8.count <= 1024 * 1024 else { show(L10n.text("剪贴板超过 1 MiB，未同步到远端。")); return }
        if !client.sendClipboard(text) { show(L10n.text("远端只支持 Latin-1 剪贴板，含中文等字符的内容未同步。")) }
    }
}
