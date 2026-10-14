import Foundation
import Network
import Security
import UniformTypeIdentifiers
import WorkbenchCore
import Darwin

public final class FilePreviewServer: @unchecked Sendable {
    public let root: String
    public let allowsScripts: Bool
    public private(set) var port: UInt16 = 0
    private let token: String
    private let transport: SSHTransport
    private let host: HostProfile?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "farport.preview.http")
    private let workers = DispatchSemaphore(value: 4)
    private let cancellation = CancellationFlag()
    private let lock = NSLock()
    private var connections: [UUID: NWConnection] = [:]

    public init(transport: SSHTransport, host: HostProfile?, directory: String, allowsScripts: Bool = false) throws {
        let client = try transport.files(host); defer { client.close() }
        if host == nil, let canonical = Darwin.realpath(directory, nil) { root = String(cString: canonical); free(canonical) }
        else { root = try client.realpath(directory) }
        guard root != "/" else { throw WorkbenchError.message("不能将文件系统根目录作为网页预览范围。请选择报告所在目录。") }
        self.transport = transport; self.host = host; self.allowsScripts = allowsScripts
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WorkbenchError.message("无法生成预览访问令牌。") }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() }; if case .failed = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else { listener.cancel(); throw WorkbenchError.message("无法启动本机文件预览服务。") }
        self.port = port.rawValue
    }
    deinit { stop() }
    public var isRunning: Bool { !cancellation.isCancelled }
    public func url(for filename: String) throws -> URL {
        guard RemotePath.validName(filename), isRunning else { throw WorkbenchError.message("预览服务已停止或文件名无效。") }
        return URL(string: "http://127.0.0.1:\(port)/\(token)/")!.appendingPathComponent(filename)
    }
    public func stop() {
        cancellation.cancel(); listener.cancel()
        lock.lock(); let current = Array(connections.values); connections.removeAll(); lock.unlock()
        current.forEach { $0.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        guard !cancellation.isCancelled, workers.wait(timeout: .now()) == .success else { connection.cancel(); return }
        let identifier = UUID()
        lock.lock(); connections[identifier] = connection; lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { connection.stateUpdateHandler = nil; self?.release(identifier) }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 120) { connection.cancel() }
        receive(connection, data: Data())
    }
    private func release(_ identifier: UUID) {
        lock.lock(); let removed = connections.removeValue(forKey: identifier); lock.unlock()
        if removed != nil { workers.signal() }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            var header = data; if let bytes { header.append(bytes) }
            guard header.count <= 16384, error == nil else { connection.cancel(); return }
            if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                let request = String(decoding: header[..<end.lowerBound], as: UTF8.self)
                DispatchQueue.global(qos: .utility).async { self.serve(request, connection: connection) }
            } else if complete { connection.cancel() }
            else { self.receive(connection, data: header) }
        }
    }
    private func serve(_ request: String, connection: NWConnection) {
        defer { connection.cancel() }
        var started = false
        do {
            try cancellation.check()
            let lines = request.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])) else { try respond(405, connection: connection); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let separator = line.firstIndex(of: ":") else { try respond(400, connection: connection); return }
                let name = line[..<separator].lowercased()
                guard headers[name] == nil else { try respond(400, connection: connection); return }
                headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            }
            let authority = "127.0.0.1:\(port)"
            guard headers["host"] == authority, headers["sec-fetch-site"] != "cross-site",
                  headers["origin"] == nil || headers["origin"] == "http://\(authority)" else { try respond(403, connection: connection); return }
            let rawPath = first[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard let decoded = String(rawPath).removingPercentEncoding, decoded.hasPrefix("/\(token)/") else { try respond(404, connection: connection); return }
            var parts = String(decoded.dropFirst(token.count + 2)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.last == "" { parts.removeLast(); parts.append("index.html") }
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else { try respond(403, connection: connection); return }
            let client = try transport.files(host, cancellation: cancellation); defer { client.close() }
            var path = ""
            for component in root.split(separator: "/").map(String.init) + parts {
                path += "/" + component
                let attributes = try client.stat(path)
                guard !attributes.isSymbolicLink else { try respond(403, connection: connection); return }
            }
            let attributes = try client.stat(path)
            guard attributes.isRegularFile else { try respond(403, connection: connection); return }
            guard attributes.size <= 256 * 1024 * 1024 else { try respond(413, connection: connection); return }
            let local = host == nil ? try localReader(parts: parts) : nil
            let remote = client as? SFTPClient
            let remoteHandle = try remote?.openRead(path)
            defer { try? local?.close(); if let remoteHandle { try? remote?.closeHandle(remoteHandle) } }
            var start: UInt64 = 0; var end = attributes.size; var status = 200
            if let range = headers["range"] {
                guard range.hasPrefix("bytes="), !range.contains(",") else { try respond(416, connection: connection); return }
                let values = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard values.count == 2, attributes.size > 0 else { try respond(416, connection: connection); return }
                if values[0].isEmpty {
                    guard let suffix = UInt64(values[1]), suffix > 0 else { try respond(416, connection: connection); return }
                    start = attributes.size - min(suffix, attributes.size)
                } else {
                    guard let offset = UInt64(values[0]), offset < attributes.size else { try respond(416, connection: connection); return }; start = offset
                    if !values[1].isEmpty {
                        guard let last = UInt64(values[1]), last >= start else { try respond(416, connection: connection); return }
                        end = min(last, attributes.size - 1) + 1
                    }
                }
                status = 206
            }
            let mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            var extra = "Content-Type: \(mime)\r\nAccept-Ranges: bytes\r\n"
            if status == 206 { extra += "Content-Range: bytes \(start)-\(end - 1)/\(attributes.size)\r\n" }
            try send(Data(responseHeader(status, length: end - start, extra: extra).utf8), connection: connection); started = true
            if first[0] == "HEAD" { return }
            while start < end {
                try cancellation.check()
                let limit = Int(min(1024 * 1024, end - start))
                let bytes: Data
                if let local { try local.seek(toOffset: start); bytes = try local.read(upToCount: limit) ?? Data() }
                else if let remoteHandle, let remote { bytes = try remote.read(remoteHandle, offset: start, length: limit) }
                else { throw WorkbenchError.message("预览读取通道不可用。") }
                guard !bytes.isEmpty else { throw WorkbenchError.message("文件在预览期间变化。") }
                try send(bytes, connection: connection); start += UInt64(bytes.count)
            }
        } catch { if !started { try? respond(404, connection: connection) } }
    }
    private func responseHeader(_ status: Int, length: UInt64, extra: String = "") -> String {
        let script = allowsScripts ? "'self' 'unsafe-inline'" : "'none'"
        let sandbox = allowsScripts ? "allow-scripts allow-same-origin" : "allow-same-origin"
        return "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Response")\r\nContent-Length: \(length)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nCross-Origin-Resource-Policy: same-origin\r\nContent-Security-Policy: default-src 'none'; script-src \(script); style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; media-src 'self'; connect-src 'self'; frame-src 'self'; base-uri 'self'; form-action 'none'; sandbox \(sandbox)\r\n\(extra)\r\n"
    }
    private func respond(_ status: Int, connection: NWConnection) throws { try send(Data(responseHeader(status, length: 0).utf8), connection: connection) }
    private func localReader(parts: [String]) throws -> FileHandle {
        var descriptor = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WorkbenchError.message("预览目录不可读。") }
        for (index, part) in parts.enumerated() {
            let child = openat(descriptor, part, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (index == parts.count - 1 ? 0 : O_DIRECTORY))
            Darwin.close(descriptor)
            guard child >= 0 else { throw WorkbenchError.message("预览路径不安全或不可读。") }; descriptor = child
        }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor); throw WorkbenchError.message("只允许预览普通文件。")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private func send(_ data: Data, connection: NWConnection) throws {
        let sent = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { _ in sent.signal() })
        guard sent.wait(timeout: .now() + 15) == .success else { throw WorkbenchError.message("浏览器读取超时。") }
        if case .cancelled = connection.state { throw WorkbenchError.cancelled }
        if case .failed = connection.state { throw WorkbenchError.message("浏览器已断开。") }
    }
}
