import Foundation
import CoreGraphics
import WorkbenchCore

public enum RFBQuality: String, CaseIterable, Sendable {
    case lossless, balanced, smooth
    /// Tight 的 JPEG 质量伪编码（-32+q）与压缩级别伪编码（-256+level）；lossless 不请求 JPEG。
    var pseudoEncodings: [Int32] {
        switch self {
        case .lossless: return [-256 + 2]
        case .balanced: return [-32 + 7, -256 + 4]
        case .smooth: return [-32 + 4, -256 + 7]
        }
    }
}

public struct RFBServerInfo: Sendable {
    public let name: String
    public let width: Int
    public let height: Int
    public let version: String
    /// 服务端为 Apple 屏幕共享（3.889 或提供 ARD 认证）。
    public let isMacOS: Bool
    public let securityType: UInt8
}

public enum RFBCredentialKind: Sendable { case password, usernameAndPassword }
public struct RFBCredentials: Sendable {
    public let username: String
    public let password: String
    public init(username: String = "", password: String) { self.username = username; self.password = password }
}

/// 回调均在协议线程上调用（凭据回调会阻塞协议线程直到返回）。
public struct RFBClientEvents {
    public var credentials: (RFBCredentialKind) -> RFBCredentials? = { _ in nil }
    public var connected: (RFBServerInfo) -> Void = { _ in }
    public var resized: (Int, Int) -> Void = { _, _ in }
    public var updated: () -> Void = {}
    public var cursor: (_ rgba: [UInt8], _ width: Int, _ height: Int, _ hotX: Int, _ hotY: Int) -> Void = { _, _, _, _, _ in }
    public var clipboard: (String) -> Void = { _ in }
    public var extendedClipboard: (Bool) -> Void = { _ in }
    public var bell: () -> Void = {}
    public var closed: (Error?) -> Void = { _ in }
    public init() {}
}

public final class RFBClient: @unchecked Sendable {
    public let framebuffer = RFBFramebuffer()
    public var events = RFBClientEvents()
    /// 测试可强制只请求某种编码；nil 时按默认优先级。
    public var preferredEncodings: [Int32]?
    private let stream: RFBStream
    private let writeQueue = DispatchQueue(label: "local.sshworkbench.rfb.write")
    private let stateLock = NSLock()
    private lazy var decoders = RFBDecoders(framebuffer: framebuffer)
    private var paused = false
    private var quality: RFBQuality
    private var stopping = false
    private var extendedClipboard = false
    private var pendingProvide: String?
    private var pingSent: TimeInterval?
    private var latestLatency: TimeInterval?
    private var frameCount: UInt64 = 0
    public private(set) var info: RFBServerInfo?
    /// 编码统计：最近一帧使用的主要编码名称。
    public private(set) var lastEncoding = ""
    /// 当前协议阶段（诊断用，出错时附在错误信息中；不含凭据）。
    private var stage = "握手"
    private let started = ProcessInfo.processInfo.systemUptime
    private func enter(_ value: String) { stateLock.withLock { stage = value }; NSLog("Farport RFB %.2fs %@", ProcessInfo.processInfo.systemUptime - started, value) }

    public static let extendedClipboardEncoding: Int32 = Int32(bitPattern: 0xC0A1E5CE)

    public init(stream: RFBStream, quality: RFBQuality = .balanced) { self.stream = stream; self.quality = quality }

    public var tightRGBOrder: Bool { get { decoders.tightRGBOrder } set { decoders.tightRGBOrder = newValue } }
    public var counters: (received: UInt64, sent: UInt64) { stream.counters }
    public var statistics: (frames: UInt64, latency: TimeInterval?) { stateLock.withLock { (frameCount, latestLatency) } }
    /// 累计花在接收与解码帧更新上的时间（含等待该帧剩余数据）。
    public var decodeTime: TimeInterval { stateLock.withLock { decodeSeconds } }
    private var decodeSeconds: TimeInterval = 0
    public var supportsExtendedClipboard: Bool { stateLock.withLock { extendedClipboard } }

    public func start() {
        let thread = Thread { [self] in
            var failure: Error?
            do { try run() } catch {
                let current = stateLock.withLock { stage }
                NSLog("Farport RFB 失败于「%@」：%@", current, String(describing: error))
                if case .io(let detail) = error as? RFBError { failure = RFBError.io(detail + "（" + current + "）") } else { failure = error }
            }
            let intentional = stateLock.withLock { stopping }
            stream.close()
            events.closed(intentional ? nil : failure)
        }
        thread.name = "Farport RFB"; thread.qualityOfService = .userInteractive
        thread.start()
    }
    public func stop() { stateLock.withLock { stopping = true }; stream.close() }

    // MARK: 协议主流程

    private func run() throws {
        let banner = String(decoding: try stream.read(12), as: UTF8.self)
        guard banner.hasPrefix("RFB "), banner.hasSuffix("\n"), banner.count == 12 else { throw RFBError.protocolViolation(L10n.text("不是 VNC 服务") + "（\(banner.prefix(11).trimmingCharacters(in: .controlCharacters))）") }
        let major = Int(banner.dropFirst(4).prefix(3)) ?? 0, minor = Int(banner.dropFirst(8).prefix(3)) ?? 0
        guard major == 3 else { throw RFBError.unsupported("协议版本 \(banner.trimmingCharacters(in: .newlines))") }
        let version = minor >= 8 ? 8 : minor == 7 ? 7 : 3
        try stream.write(Array("RFB 003.00\(version)\n".utf8))
        var offered: [UInt8]
        if version == 3 {
            let type = try stream.u32()
            if type == 0 { throw RFBError.authenticationFailed(try reason()) }
            offered = [UInt8(truncatingIfNeeded: type)]
        } else {
            let count = Int(try stream.u8())
            if count == 0 { throw RFBError.authenticationFailed(try reason()) }
            offered = try stream.read(count)
        }
        enter("选择认证方式（服务端 \(banner.trimmingCharacters(in: .newlines))，提供 \(offered.map(String.init).joined(separator: ",")))")
        let isMacOS = minor == 889 || offered.contains(30)
        let chosen: UInt8
        if offered.contains(30) { chosen = 30 } else if offered.contains(2) { chosen = 2 } else if offered.contains(1) { chosen = 1 }
        else { throw RFBError.unsupported(L10n.text("服务端认证方式 \(offered.map(String.init).joined(separator: ","))（支持：无认证、VNC 口令、macOS 账号）")) }
        if version != 3 { try stream.write([chosen]) }
        switch chosen {
        case 2:
            enter("等待输入 VNC 口令")
            guard let credentials = events.credentials(.password) else { throw RFBError.cancelled }
            enter("发送 VNC 口令认证")
            try stream.write(try RFBSecurity.vncResponse(challenge: try stream.read(16), password: credentials.password))
        case 30:
            let generator = try stream.read(2)
            let length = Int(try stream.u16())
            let prime = try stream.read(length), serverPublic = try stream.read(length)
            enter("等待输入 macOS 账号")
            guard let credentials = events.credentials(.usernameAndPassword) else { throw RFBError.cancelled }
            enter("发送 macOS 账号认证")
            try stream.write(try RFBSecurity.ardResponse(generator: generator, prime: prime, serverPublic: serverPublic, username: credentials.username, password: credentials.password))
        default: break
        }
        enter("等待认证结果")
        if chosen != 1 || version == 8 {
            let result = try stream.u32()
            if result != 0 { throw RFBError.authenticationFailed(version == 8 ? try reason() : "") }
        }
        enter("初始化桌面")
        try stream.write([1]) // ClientInit：共享连接，不断开其他查看者
        let width = Int(try stream.u16()), height = Int(try stream.u16())
        _ = try stream.read(16)
        let nameLength = Int(try stream.u32())
        guard nameLength <= 65536 else { throw RFBError.protocolViolation("桌面名称过长") }
        let name = String(decoding: try stream.read(nameLength), as: UTF8.self)
        framebuffer.resize(width: width, height: height)
        let serverInfo = RFBServerInfo(name: name, width: width, height: height, version: banner.trimmingCharacters(in: .newlines), isMacOS: isMacOS, securityType: chosen)
        stateLock.withLock { info = serverInfo }
        events.connected(serverInfo)
        enter("接收画面")
        try stream.write([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        sendEncodings()
        requestUpdate(incremental: false)
        while true { try handleMessage() }
    }

    private func reason() throws -> String {
        let length = Int(try stream.u32())
        guard length <= 65536 else { throw RFBError.protocolViolation("原因过长") }
        return String(decoding: try stream.read(length), as: UTF8.self)
    }

    private func handleMessage() throws {
        let type = try stream.u8()
        switch type {
        case 0: try framebufferUpdate()
        case 1: _ = try stream.read(1); _ = try stream.u16(); try stream.skip(Int(try stream.u16()) * 6)
        case 2: events.bell()
        case 3:
            try stream.skip(3)
            let length = try stream.s32()
            if length >= 0 {
                guard length <= 16 * 1024 * 1024 else { throw RFBError.protocolViolation("剪贴板过大") }
                let bytes = try stream.read(Int(length))
                events.clipboard(String(bytes.map { Character(Unicode.Scalar($0)) }).replacingOccurrences(of: "\r\n", with: "\n"))
            } else {
                guard length != Int32.min, -length <= 16 * 1024 * 1024 else { throw RFBError.protocolViolation("剪贴板过大") }
                try extendedClipboardMessage(try stream.read(Int(-length)))
            }
        case 150: break // EndOfContinuousUpdates（第 2 期启用连续更新）
        default: throw RFBError.protocolViolation("未知服务端消息 \(type)")
        }
    }

    private func framebufferUpdate() throws {
        try stream.skip(1)
        let count = Int(try stream.u16())
        // 流水线：收到更新头就请求下一帧，服务端编码与网络传输和本端解码并行，不必每帧等一次往返。
        if stateLock.withLock({ !paused }) { requestUpdate(incremental: true) }
        let decodeStarted = ProcessInfo.processInfo.systemUptime
        var dirty: CGRect?
        var names: [Int32: Int] = [:]
        for _ in 0..<count {
            let x = Int(try stream.u16()), y = Int(try stream.u16()), width = Int(try stream.u16()), height = Int(try stream.u16())
            let encoding = try stream.s32()
            let rect = RFBRect(x: x, y: y, width: width, height: height)
            switch encoding {
            case 0: try decoders.raw(rect, stream)
            case 1: try decoders.copyRect(rect, stream)
            case 5: try decoders.hextile(rect, stream)
            case 7: try decoders.tight(rect, stream)
            case 16: try decoders.zrle(rect, stream)
            case -239:
                let rgba = try decoders.cursor(rect, stream)
                events.cursor(rgba, width, height, x, y); continue
            case -223:
                framebuffer.resize(width: width, height: height); events.resized(width, height); dirty = nil; continue
            case -308:
                let screens = Int(try stream.u8()); try stream.skip(3 + screens * 16)
                if y == 0 || x == 0 { framebuffer.resize(width: width, height: height); events.resized(width, height); dirty = nil }
                continue
            case -224: break
            default: throw RFBError.protocolViolation("未请求的编码 \(encoding)")
            }
            if encoding == -224 { break }
            names[encoding, default: 0] += width * height
            let area = CGRect(x: x, y: y, width: width, height: height)
            dirty = dirty.map { $0.union(area) } ?? area
        }
        if let dirty { framebuffer.markDirty(dirty) }
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.withLock {
            frameCount &+= 1
            if let sent = pingSent, dirty.map({ $0.contains(CGPoint(x: 0, y: 0)) }) == true { latestLatency = now - sent; pingSent = nil }
            if let main = names.max(by: { $0.value < $1.value })?.key { lastEncoding = Self.name(main) }
        }
        stateLock.withLock { decodeSeconds += ProcessInfo.processInfo.systemUptime - decodeStarted }
        events.updated()
    }

    static func name(_ encoding: Int32) -> String {
        switch encoding { case 0: return "Raw"; case 1: return "CopyRect"; case 5: return "Hextile"; case 7: return "Tight"; case 16: return "ZRLE"; default: return String(encoding) }
    }

    // MARK: 客户端消息（可从任意线程调用）

    private func send(_ bytes: [UInt8]) { writeQueue.async { [stream] in try? stream.write(bytes) } }
    private static func u16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
    private static func u32(_ value: UInt32) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }

    private func sendEncodings() {
        let base: [Int32] = preferredEncodings ?? [7, 16, 5, 1, 0]
        let pseudo: [Int32] = [-239, -223, -224, -308, Self.extendedClipboardEncoding]
        let list = base + stateLock.withLock({ quality }).pseudoEncodings + pseudo
        send([2, 0] + Self.u16(list.count) + list.flatMap { Self.u32(UInt32(bitPattern: $0)) })
    }
    public func setQuality(_ value: RFBQuality) { stateLock.withLock { quality = value }; sendEncodings(); requestUpdate(incremental: false) }

    public func requestUpdate(incremental: Bool) {
        let width = framebuffer.width, height = framebuffer.height
        guard width > 0, height > 0 else { return }
        send([3, incremental ? 1 : 0, 0, 0, 0, 0] + Self.u16(width) + Self.u16(height))
    }
    /// 暂停时不再请求画面（标签不可见时节省带宽）；恢复时立即请求完整画面。
    public func setPaused(_ value: Bool) {
        let resumed: Bool = stateLock.withLock { defer { paused = value }; return paused && !value }
        if resumed { requestUpdate(incremental: false) }
    }
    /// 近似往返延迟：请求左上角 1×1 区域的完整更新，收到覆盖该点的更新时记录耗时。
    public func ping() {
        let ready: Bool = stateLock.withLock { guard pingSent == nil || ProcessInfo.processInfo.systemUptime - pingSent! > 5 else { return false }; pingSent = ProcessInfo.processInfo.systemUptime; return true }
        if ready, info != nil { send([3, 0, 0, 0, 0, 0, 0, 1, 0, 1]) }
    }

    public func key(_ keysym: UInt32, down: Bool) { send([4, down ? 1 : 0, 0, 0] + Self.u32(keysym)) }
    public func pointer(x: Int, y: Int, buttons: UInt8) {
        let clampedX = max(0, min(framebuffer.width - 1, x)), clampedY = max(0, min(framebuffer.height - 1, y))
        send([5, buttons] + Self.u16(clampedX) + Self.u16(clampedY))
    }

    // MARK: 剪贴板

    /// 发送本地文本。扩展剪贴板用 UTF-8（先通知，服务端请求时提供）；旧协议仅限 Latin-1，含其他字符时返回 false 且不发送。
    @discardableResult public func sendClipboard(_ text: String) -> Bool {
        if supportsExtendedClipboard {
            stateLock.withLock { pendingProvide = text }
            send([6, 0, 0, 0] + Self.u32(UInt32(bitPattern: -4)) + Self.u32(1 << 27 | 1))
            return true
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) else { return false }
        let bytes = normalized.unicodeScalars.map { UInt8($0.value) }
        send([6, 0, 0, 0] + Self.u32(UInt32(bytes.count)) + bytes)
        return true
    }

    private func extendedClipboardMessage(_ payload: [UInt8]) throws {
        guard payload.count >= 4 else { throw RFBError.protocolViolation("扩展剪贴板") }
        let flags = UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3])
        let text = flags & 1 != 0
        if flags & (1 << 24) != 0 { // caps：回复本端能力（文本，最大 1 MiB），并启用 UTF-8 剪贴板
            stateLock.withLock { extendedClipboard = true }
            events.extendedClipboard(true)
            let actions: UInt32 = 1 << 24 | 1 << 25 | 1 << 26 | 1 << 27 | 1 << 28
            send([6, 0, 0, 0] + Self.u32(UInt32(bitPattern: -8)) + Self.u32(actions | 1) + Self.u32(1024 * 1024))
        } else if flags & (1 << 25) != 0, text { // request：提供本端最近一次通知的文本
            guard let value = stateLock.withLock({ pendingProvide }) else { return }
            var bytes = Array(value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8) + [0]
            if bytes.count > 1024 * 1024 { bytes = Array(bytes.prefix(1024 * 1024 - 1)) + [0] }
            let body = rfbDeflate(Self.u32(UInt32(bytes.count)) + bytes)
            send([6, 0, 0, 0] + Self.u32(UInt32(bitPattern: -Int32(4 + body.count))) + Self.u32(1 << 28 | 1) + body)
        } else if flags & (1 << 27) != 0 || flags & (1 << 26) != 0, text { // notify/peek：服务端有新文本，请求之
            send([6, 0, 0, 0] + Self.u32(UInt32(bitPattern: -4)) + Self.u32(1 << 25 | 1))
        } else if flags & (1 << 28) != 0, text { // provide：zlib 流内依次为各格式的长度与数据
            let inflater = RFBInflater()
            let data = try inflater.inflate(Array(payload.dropFirst(4)))
            guard data.count >= 4 else { return }
            let length = Int(UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3]))
            guard length <= data.count - 4 else { throw RFBError.protocolViolation("扩展剪贴板长度") }
            var bytes = Array(data[4..<4 + length]); if bytes.last == 0 { bytes.removeLast() }
            events.clipboard(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n"))
        }
    }
}
