import Foundation
import Darwin
import WorkbenchCore

public struct SFTPFailure: LocalizedError {
    public let code: UInt32
    public let message: String
    public var errorDescription: String? {
        switch code {
        case 2: return "文件或目录不存在：\(message)"
        case 3: return "远端拒绝访问，请检查权限：\(message)"
        case 4: return "远端文件操作失败（可能是磁盘已满、文件已存在或权限不足）：\(message)"
        default: return "SFTP \(code)：\(message)"
        }
    }
}

public final class SFTPClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private let errors = CapturedOutput()
    private let errorReader = DispatchGroup()
    private let cancellation: CancellationFlag
    private var requestID: UInt32 = 0
    private let lock = NSRecursiveLock()
    private var extensions: Set<String> = []
    private var closed = false

    public init(transport: SSHTransport, host: HostProfile, cancellation: CancellationFlag, reuseConnection: Bool = true) throws {
        self.cancellation = cancellation
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try transport.options(for: host, reuseConnection: reuseConnection) + ["-s", host.address, "sftp"]
        process.environment = transport.environment(for: host)
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        try process.run()
        let errorHandle = error.fileHandleForReading; let capturedErrors = errors
        let errorReader = errorReader; errorReader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { errorReader.leave() }
            while let data = try? errorHandle.read(upToCount: 8192), !data.isEmpty { capturedErrors.append(data, limit: 65536) }
        }
        let outputFD = output.fileHandleForReading.fileDescriptor
        let inputFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(outputFD, F_SETFL, fcntl(outputFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
        do {
            var packet = PacketWriter(); packet.byte(1); packet.uint32(3); try send(packet)
            var response = PacketReader(try receive())
            guard try response.byte() == 2, try response.uint32() == 3 else { throw WorkbenchError.protocolViolation("服务器未协商 SFTP v3") }
            while response.remaining > 0 { extensions.insert(try response.string()); _ = try response.string() }
        } catch { close(); throw error }
    }

    deinit { close() }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
    }

    private func wait(_ descriptor: Int32, events: Int16, deadline: Date) throws {
        while true {
            try cancellation.check()
            if Date() > deadline { throw WorkbenchError.message("SFTP 响应超时；可以在恢复网络后重试或续传。") }
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&pollDescriptor, 1, 250)
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw WorkbenchError.message("SFTP 连接不可用。") }
        }
    }
    private func connectionError() -> Error {
        _ = errorReader.wait(timeout: .now() + 0.1)
        let message = String(decoding: errors.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkbenchError.message(message.isEmpty ? "SSH 连接已关闭，请重新连接。" : message)
    }
    private func send(_ packet: PacketWriter) throws {
        let data = packet.framed; let descriptor = input.fileHandleForWriting.fileDescriptor
        let deadline = Date().addingTimeInterval(120)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written > 0 { offset += written }
                else if errno != EAGAIN && errno != EINTR { throw connectionError() }
            }
        }
    }
    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count); let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(120)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
                let received = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
                if received > 0 { offset += received }
                else if received == 0 { throw connectionError() }
                else if errno != EAGAIN && errno != EINTR { throw connectionError() }
            }
        }
        return data
    }
    private func receive() throws -> Data {
        var header = PacketReader(try readExactly(4)); let length = try header.uint32()
        guard length >= 1, length <= 8 * 1024 * 1024 else { throw WorkbenchError.protocolViolation("响应包长度非法") }
        return try readExactly(Int(length))
    }
    private func enqueue(_ type: UInt8, _ payload: (inout PacketWriter) -> Void) throws -> UInt32 {
        requestID &+= 1
        var packet = PacketWriter(); packet.byte(type); packet.uint32(requestID); payload(&packet)
        try send(packet); return requestID
    }
    private func response(_ expected: UInt32) throws -> (UInt8, PacketReader) {
        var reader = PacketReader(try receive()); let type = try reader.byte()
        guard try reader.uint32() == expected else { throw WorkbenchError.protocolViolation("请求序号不匹配") }
        return (type, reader)
    }
    private func status(_ reader: inout PacketReader, allowEOF: Bool = false) throws -> Bool {
        let code = try reader.uint32(); let message = try reader.string(); _ = try reader.string()
        if code == 0 { return true }
        if code == 1 && allowEOF { return false }
        throw SFTPFailure(code: code, message: message)
    }
    private func request(_ type: UInt8, expecting expected: UInt8, _ payload: (inout PacketWriter) -> Void) throws -> PacketReader {
        let identifier = try enqueue(type, payload); var (responseType, reader) = try response(identifier)
        if responseType == 101 { _ = try status(&reader) }
        guard responseType == expected else { throw WorkbenchError.protocolViolation("响应类型 \(responseType) 不符合预期 \(expected)") }
        return reader
    }
    private func operation(_ type: UInt8, _ payload: (inout PacketWriter) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let identifier = try enqueue(type, payload); var (kind, reader) = try response(identifier)
        guard kind == 101 else { throw WorkbenchError.protocolViolation("缺少操作结果") }; _ = try status(&reader)
    }
    public func realpath(_ path: String = ".") throws -> String {
        lock.lock(); defer { lock.unlock() }
        var reader = try request(16, expecting: 104) { $0.string(path) }
        guard try reader.uint32() >= 1 else { throw WorkbenchError.protocolViolation("路径解析结果为空") }
        return try reader.string()
    }
    public func stat(_ path: String, followLinks: Bool = false) throws -> FileAttributes {
        lock.lock(); defer { lock.unlock() }
        var reader = try request(followLinks ? 17 : 7, expecting: 105) { $0.string(path) }
        return try reader.attributes()
    }
    public func statIfExists(_ path: String) throws -> FileAttributes? {
        do { return try stat(path) } catch let failure as SFTPFailure where failure.code == 2 { return nil }
    }
    public func list(_ path: String) throws -> [RemoteFile] {
        let result = try listForBrowsing(path)
        guard result.skipped == 0 else { throw WorkbenchError.message("目录中有 \(result.skipped) 个非 UTF-8 或含控制字符的文件名。为避免漏传或误删，已停止递归操作；请先在目标主机处理异常文件名。") }
        return result.files
    }
    public func listForBrowsing(_ path: String) throws -> (files: [RemoteFile], skipped: Int) {
        lock.lock(); defer { lock.unlock() }
        var opened = try request(11, expecting: 102) { $0.string(path) }; let handle = try opened.bytes()
        defer { try? closeHandle(handle) }
        var files: [RemoteFile] = []
        var skipped = 0
        while true {
            let identifier = try enqueue(12) { $0.bytes(handle) }; var (kind, reader) = try response(identifier)
            if kind == 101 { if try !status(&reader, allowEOF: true) { break }; throw WorkbenchError.protocolViolation("目录返回了空状态") }
            guard kind == 104 else { throw WorkbenchError.protocolViolation("目录响应格式错误") }
            let count = try reader.uint32()
            guard count <= 100_000 else { throw WorkbenchError.protocolViolation("单批目录条目过多") }
            for _ in 0..<count {
                guard let file = try reader.directoryEntry(parent: path) else { skipped += 1; continue }
                if file.name == "." || file.name == ".." { continue }
                files.append(file)
            }
            guard files.count + skipped <= 1_000_000 else { throw WorkbenchError.message("目录超过一百万项，请按子目录浏览。") }
        }
        return (files.sorted { left, right in
            if left.attributes.isDirectory != right.attributes.isDirectory { return left.attributes.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }, skipped)
    }
    public func openRead(_ path: String) throws -> Data { try open(path, flags: 1) }
    public func openWrite(_ path: String, truncate: Bool = false, exclusive: Bool = false) throws -> Data { try open(path, flags: 2 | 8 | (truncate ? 16 : 0) | (exclusive ? 32 : 0)) }
    private func open(_ path: String, flags: UInt32) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var reader = try request(3, expecting: 102) { $0.string(path); $0.uint32(flags); $0.uint32(4); $0.uint32(0o600) }
        return try reader.bytes()
    }
    public func closeHandle(_ handle: Data) throws { try operation(4) { $0.bytes(handle) } }
    public func read(_ handle: Data, offset: UInt64, length: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard length > 0, length <= 2 * 1024 * 1024 else { return Data() }
        var requests: [(UInt32, Int)] = []
        var requested = 0
        while requested < length {
            let chunk = min(65536, length - requested); let position = offset + UInt64(requested)
            let identifier = try enqueue(5) { $0.bytes(handle); $0.uint64(position); $0.uint32(UInt32(chunk)) }
            requests.append((identifier, chunk)); requested += chunk
        }
        var data = Data(); var ended = false; var firstError: Error?
        for (identifier, requestedLength) in requests {
            do {
                var (kind, reader) = try response(identifier)
                if kind == 101 { _ = try status(&reader, allowEOF: true); ended = true; continue }
                guard kind == 103 else { throw WorkbenchError.protocolViolation("读取响应格式错误") }
                let chunk = try reader.bytes()
                guard chunk.count <= requestedLength else { throw WorkbenchError.protocolViolation("读取返回了过多数据") }
                if !ended { data.append(chunk) }
                if chunk.count < requestedLength { ended = true }
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
        return data
    }
    public func write(_ handle: Data, offset: UInt64, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        var requests: [UInt32] = []; var position = 0
        while position < data.count {
            let end = min(data.count, position + 65536); let chunk = data.subdata(in: position..<end)
            let remoteOffset = offset + UInt64(position)
            requests.append(try enqueue(6) { $0.bytes(handle); $0.uint64(remoteOffset); $0.bytes(chunk) }); position = end
        }
        var firstError: Error?
        for identifier in requests {
            do { var (kind, reader) = try response(identifier); guard kind == 101 else { throw WorkbenchError.protocolViolation("写入响应格式错误") }; _ = try status(&reader) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
    public func mkdir(_ path: String, permissions: UInt32 = 0o755) throws { try operation(14) { $0.string(path); $0.uint32(4); $0.uint32(permissions & 0o777) } }
    public func remove(_ path: String, directory: Bool = false) throws { try operation(directory ? 15 : 13) { $0.string(path) } }
    public func rename(_ source: String, to destination: String, overwrite: Bool = false) throws {
        if overwrite {
            guard extensions.contains("posix-rename@openssh.com") else { throw WorkbenchError.message("此服务器不支持原子覆盖；请另存为新名称。") }
            try operation(200) { $0.string("posix-rename@openssh.com"); $0.string(source); $0.string(destination) }
        } else { try operation(18) { $0.string(source); $0.string(destination) } }
    }
    public func chmod(_ path: String, permissions: UInt32) throws { try operation(9) { $0.string(path); $0.uint32(4); $0.uint32(permissions & 0o777) } }
    public func setModified(_ path: String, modified: UInt32) throws { try operation(9) { $0.string(path); $0.uint32(8); $0.uint32(modified); $0.uint32(modified) } }
    public func sync(_ handle: Data) throws {
        if extensions.contains("fsync@openssh.com") { try operation(200) { $0.string("fsync@openssh.com"); $0.bytes(handle) } }
    }
    public func preview(_ path: String, offset: UInt64 = 0, limit: Int = 512 * 1024) throws -> Data {
        guard limit >= 0, limit <= 8 * 1024 * 1024 else { throw WorkbenchError.message("预览长度超限。") }
        guard try stat(path, followLinks: true).isRegularFile else { throw WorkbenchError.message("只预览普通文件，不读取设备、管道或套接字。") }
        let handle = try openRead(path); defer { try? closeHandle(handle) }
        var data = Data()
        while data.count < limit {
            let chunk = try read(handle, offset: offset + UInt64(data.count), length: min(limit - data.count, 2 * 1024 * 1024))
            guard !chunk.isEmpty else { break }; data.append(chunk)
        }
        return data
    }
    public func saveText(_ path: String, data: Data, expected: FileAttributes, original: Data? = nil) throws {
        let current = try stat(path)
        guard current.size == expected.size, current.modified == expected.modified, !current.isSymbolicLink else { throw WorkbenchError.message("文件已在远端发生变化，或它是符号链接。请重新读取后再保存。") }
        if let original, try preview(path, limit: original.count + 1) != original { throw WorkbenchError.message("文件内容已在远端发生变化，未覆盖。") }
        let temporary = path + ".swb-edit-" + UUID().uuidString
        let handle = try openWrite(temporary, exclusive: true)
        do {
            try write(handle, offset: 0, data: data); try sync(handle); try closeHandle(handle)
            try chmod(temporary, permissions: expected.permissions)
            let beforeRename = try stat(path)
            guard beforeRename.size == expected.size, beforeRename.modified == expected.modified else { throw WorkbenchError.message("保存期间远端文件发生变化，未覆盖。") }
            if let original, try preview(path, limit: original.count + 1) != original { throw WorkbenchError.message("保存期间远端内容发生变化，未覆盖。") }
            try rename(temporary, to: path, overwrite: true)
        } catch { try? closeHandle(handle); try? remove(temporary); throw error }
    }
    public func removeRecursively(_ path: String, depth: Int = 0) throws {
        guard path != "/", !path.isEmpty, depth < 128 else { throw WorkbenchError.message("拒绝删除根目录或过深的目录树。") }
        let attributes = try stat(path)
        if attributes.isDirectory {
            for entry in try list(path) { try removeRecursively(entry.path, depth: depth + 1) }
            try remove(path, directory: true)
        } else { try remove(path) }
    }
}
