import Foundation
import Darwin
import WorkbenchCore

/// RFB 字节流：读写两个文件描述符（`ssh -W` 子进程的管道，或直连套接字的同一描述符）。读取在协议线程上阻塞进行，写入经串行锁保护，可从任意线程调用。
public final class RFBStream: @unchecked Sendable {
    private let readDescriptor: Int32
    private let writeDescriptor: Int32
    private let ownsDescriptors: Bool
    private var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    private var start = 0, end = 0
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false
    private var received: UInt64 = 0
    private var sent: UInt64 = 0

    public init(readDescriptor: Int32, writeDescriptor: Int32, ownsDescriptors: Bool = true) {
        self.readDescriptor = readDescriptor; self.writeDescriptor = writeDescriptor; self.ownsDescriptors = ownsDescriptors
    }
    deinit { close() }

    /// 已接收、已发送的字节总数，用于状态栏带宽统计。
    public var counters: (received: UInt64, sent: UInt64) { stateLock.withLock { (received, sent) } }
    public var isClosed: Bool { stateLock.withLock { closed } }

    public func close() {
        let shouldClose: Bool = stateLock.withLock { defer { closed = true }; return !closed }
        guard shouldClose else { return }
        if ownsDescriptors {
            Darwin.shutdown(readDescriptor, SHUT_RDWR)
            Darwin.close(readDescriptor)
            if writeDescriptor != readDescriptor { Darwin.close(writeDescriptor) }
        }
    }

    private func fill(minimum: Int) throws {
        if end - start >= minimum { return }
        if start > 0 { buffer.withUnsafeMutableBufferPointer { pointer in _ = memmove(pointer.baseAddress!, pointer.baseAddress! + start, end - start) }; end -= start; start = 0 }
        if minimum > buffer.count { buffer += [UInt8](repeating: 0, count: minimum - buffer.count) }
        while end < minimum {
            if isClosed { throw RFBError.closed }
            let count = buffer.withUnsafeMutableBufferPointer { pointer in Darwin.read(readDescriptor, pointer.baseAddress! + end, pointer.count - end) }
            if count < 0 { if errno == EINTR { continue }; throw isClosed ? RFBError.closed : RFBError.io(String(cString: strerror(errno))) }
            if count == 0 { throw RFBError.closed }
            end += count
            stateLock.withLock { received &+= UInt64(count) }
        }
    }

    public func read(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        if count > 64 * 1024 * 1024 { throw RFBError.protocolViolation("数据块过大") }
        try fill(minimum: count)
        defer { start += count }
        return Array(buffer[start..<start + count])
    }
    /// 直接把数据读进调用方内存，避免大块像素数据多一次复制。
    public func read(into destination: UnsafeMutableRawPointer, count: Int) throws {
        var copied = 0
        while copied < count {
            if end == start { try fill(minimum: 1) }
            let chunk = min(count - copied, end - start)
            buffer.withUnsafeBufferPointer { pointer in _ = memcpy(destination + copied, pointer.baseAddress! + start, chunk) }
            start += chunk; copied += chunk
        }
    }
    public func skip(_ count: Int) throws {
        var remaining = count
        while remaining > 0 { if end == start { try fill(minimum: 1) }; let chunk = min(remaining, end - start); start += chunk; remaining -= chunk }
    }
    public func u8() throws -> UInt8 { try fill(minimum: 1); defer { start += 1 }; return buffer[start] }
    public func u16() throws -> UInt16 { try fill(minimum: 2); defer { start += 2 }; return UInt16(buffer[start]) << 8 | UInt16(buffer[start + 1]) }
    public func u32() throws -> UInt32 {
        try fill(minimum: 4); defer { start += 4 }
        return UInt32(buffer[start]) << 24 | UInt32(buffer[start + 1]) << 16 | UInt32(buffer[start + 2]) << 8 | UInt32(buffer[start + 3])
    }
    public func s32() throws -> Int32 { Int32(bitPattern: try u32()) }

    public func write(_ bytes: [UInt8]) throws {
        try writeLock.withLock {
            var offset = 0
            while offset < bytes.count {
                if isClosed { throw RFBError.closed }
                let count = bytes.withUnsafeBufferPointer { pointer in Darwin.write(writeDescriptor, pointer.baseAddress! + offset, pointer.count - offset) }
                if count < 0 { if errno == EINTR { continue }; throw isClosed ? RFBError.closed : RFBError.io(String(cString: strerror(errno))) }
                offset += count
            }
            stateLock.withLock { sent &+= UInt64(bytes.count) }
        }
    }

    /// 直连：解析地址并带超时连接，返回阻塞模式的套接字流。
    public static func connect(host: String, port: Int, timeout: TimeInterval = 10) throws -> RFBStream {
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM; hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else { throw RFBError.io(String(cString: gai_strerror(status))) }
        defer { freeaddrinfo(result) }
        var lastError = "connect failed"
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let address = candidate {
            candidate = address.pointee.ai_next
            let descriptor = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            guard descriptor >= 0 else { continue }
            let flags = fcntl(descriptor, F_GETFL)
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            var noSignal: Int32 = 1; setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var noDelay: Int32 = 1; setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            if Darwin.connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen) != 0 && errno != EINPROGRESS {
                lastError = String(cString: strerror(errno)); Darwin.close(descriptor); continue
            }
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            var socketError: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
            if poll(&poller, 1, Int32(timeout * 1000)) == 1, getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 {
                _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
                return RFBStream(readDescriptor: descriptor, writeDescriptor: descriptor)
            }
            lastError = socketError != 0 ? String(cString: strerror(socketError)) : "timeout"
            Darwin.close(descriptor)
        }
        throw RFBError.io(lastError)
    }
}

public enum RFBError: Error, Equatable, LocalizedError {
    case closed
    case io(String)
    case protocolViolation(String)
    case unsupported(String)
    case authenticationFailed(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .closed: return L10n.text("远程桌面连接已关闭")
        case .io(let detail): return L10n.text("网络错误：") + detail
        case .protocolViolation(let detail): return L10n.text("远程桌面协议错误：") + detail
        case .unsupported(let detail): return L10n.text("不支持：") + detail
        case .authenticationFailed(let detail): return detail.isEmpty ? L10n.text("认证失败，请检查用户名和密码") : L10n.text("认证失败：") + detail
        case .cancelled: return L10n.text("已取消登录")
        }
    }
}
