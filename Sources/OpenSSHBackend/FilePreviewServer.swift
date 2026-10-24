import Foundation
import Network
import Security
import UniformTypeIdentifiers
import WorkbenchCore
import Darwin

public final class FilePreviewServer: @unchecked Sendable {
    private final class Request: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        let cancellation = CancellationFlag()
        var serving = false
        init(_ connection: NWConnection) { self.connection = connection }
        func cancel() { cancellation.cancel(); connection.cancel() }
    }
    public let root: String
    public let allowsScripts: Bool
    public private(set) var port: UInt16 = 0
    private let token: String
    private let transport: SSHTransport
    private let host: HostProfile?
    private let fileName: String?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "farport.preview.http")
    private let cancellation = CancellationFlag()
    private let lock = NSLock()
    private var connections: [UUID: Request] = [:]
    private var pending: [(Request, String)] = []

    public init(transport: SSHTransport, host: HostProfile?, directory: String, allowsScripts: Bool = false, fileName: String? = nil) throws {
        guard fileName == nil || RemotePath.validName(fileName!) else { throw WorkbenchError.message(L10n.text("预览文件名无效。")) }
        let client = try transport.files(host); defer { client.close() }
        if host == nil, let canonical = Darwin.realpath(directory, nil) { root = String(cString: canonical); free(canonical) }
        else { root = try client.realpath(directory) }
        guard root != "/" else { throw WorkbenchError.message(L10n.text("不能将文件系统根目录作为网页预览范围。请选择报告所在目录。")) }
        self.transport = transport; self.host = host; self.allowsScripts = allowsScripts
        self.fileName = fileName
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WorkbenchError.message(L10n.text("无法生成预览访问令牌。")) }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { ready.signal() }
            if case .failed = state { self?.stop(); ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, !cancellation.isCancelled, let port = listener.port else { listener.cancel(); throw WorkbenchError.message(L10n.text("无法启动本机文件预览服务。")) }
        self.port = port.rawValue
    }
    deinit { stop() }
    public var isRunning: Bool { !cancellation.isCancelled }
    public func url(for filename: String) throws -> URL {
        guard RemotePath.validName(filename), isRunning else { throw WorkbenchError.message(L10n.text("预览服务已停止或文件名无效。")) }
        return URL(string: "http://127.0.0.1:\(port)/\(token)/")!.appendingPathComponent(filename)
    }
    public func stop() {
        lock.lock()
        cancellation.cancel()
        let current = Array(connections.values); connections.removeAll()
        pending.removeAll()
        lock.unlock()
        listener.cancel()
        current.forEach { $0.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        let request = Request(connection)
        lock.lock()
        guard !cancellation.isCancelled, connections.count < 32 else { lock.unlock(); connection.cancel(); return }
        connections[request.id] = request
        connection.stateUpdateHandler = { [weak self, weak request] state in
            guard let request else { return }
            switch state {
            case .cancelled:
                request.cancellation.cancel()
                self?.release(request, finished: false)
            case .failed:
                request.cancel()
                self?.release(request, finished: false)
            default: break
            }
        }
        connection.start(queue: queue)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 120) { [weak request] in request?.cancel() }
        receive(request, data: Data())
    }
    private func release(_ request: Request, finished: Bool) {
        lock.lock()
        if finished || !request.serving {
            connections.removeValue(forKey: request.id)
            pending.removeAll { $0.0.id == request.id }
        }
        lock.unlock()
        servePending()
    }
    private func servePending() {
        lock.lock()
        var ready: [(Request, String)] = []
        var active = connections.values.filter(\.serving).count
        while !cancellation.isCancelled, active < 4, !pending.isEmpty {
            let next = pending.removeFirst()
            guard !next.0.cancellation.isCancelled, connections[next.0.id] != nil else { continue }
            next.0.serving = true; active += 1; ready.append(next)
        }
        lock.unlock()
        for (request, header) in ready {
            DispatchQueue.global(qos: .utility).async {
                defer { request.cancel(); self.release(request, finished: true) }
                self.serve(header, request: request)
            }
        }
    }
    private func receive(_ request: Request, data: Data) {
        request.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, complete, error in
            guard let self, !request.cancellation.isCancelled else { request.cancel(); return }
            var header = data; if let bytes { header.append(bytes) }
            guard header.count <= 16384, error == nil else { request.cancel(); return }
            if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: header[..<end.lowerBound], as: UTF8.self)
                self.lock.lock()
                let allowed = !self.cancellation.isCancelled && !request.cancellation.isCancelled && self.connections[request.id] != nil
                if allowed { self.pending.append((request, header)) }
                self.lock.unlock()
                guard allowed else { request.cancel(); return }
                self.servePending()
            } else if complete { request.cancel() }
            else { self.receive(request, data: header) }
        }
    }
    private func serve(_ header: String, request: Request) {
        let cancellation = request.cancellation
        var started = false
        do {
            try cancellation.check()
            let lines = header.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])) else { try respond(405, request: request); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let separator = line.firstIndex(of: ":") else { try respond(400, request: request); return }
                let name = line[..<separator].lowercased()
                guard headers[name] == nil else { try respond(400, request: request); return }
                headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            }
            let authority = "127.0.0.1:\(port)"
            guard headers["host"] == authority, headers["sec-fetch-site"] != "cross-site",
                  headers["origin"] == nil || headers["origin"] == "http://\(authority)" else { try respond(403, request: request); return }
            let rawPath = first[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard let decoded = String(rawPath).removingPercentEncoding, decoded.hasPrefix("/\(token)/") else { try respond(404, request: request); return }
            var parts = String(decoded.dropFirst(token.count + 2)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.last == "" { parts.removeLast(); parts.append("index.html") }
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else { try respond(403, request: request); return }
            if let fileName, parts != [fileName] { try respond(403, request: request); return }
            let client = try transport.files(host, cancellation: cancellation); defer { client.close() }
            var path = ""
            for component in root.split(separator: "/").map(String.init) + parts {
                path += "/" + component
                let attributes = try client.stat(path)
                guard !attributes.isSymbolicLink else { try respond(403, request: request); return }
            }
            let attributes = try client.stat(path)
            guard attributes.isRegularFile else { try respond(403, request: request); return }
            guard attributes.size <= (fileName == nil ? 256 * 1024 * 1024 : 32 * 1024 * 1024 * 1024) else { try respond(413, request: request); return }
            let local = host == nil ? try localReader(parts: parts) : nil
            let remote = client as? SFTPClient
            let remoteHandle = try remote?.openRead(path)
            defer { try? local?.close(); if let remoteHandle { try? remote?.closeHandle(remoteHandle) } }
            var start: UInt64 = 0; var end = attributes.size; var status = 200
            if let range = headers["range"] {
                guard range.hasPrefix("bytes="), !range.contains(",") else { try respond(416, request: request); return }
                let values = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard values.count == 2, attributes.size > 0 else { try respond(416, request: request); return }
                if values[0].isEmpty {
                    guard let suffix = UInt64(values[1]), suffix > 0 else { try respond(416, request: request); return }
                    start = attributes.size - min(suffix, attributes.size)
                } else {
                    guard let offset = UInt64(values[0]), offset < attributes.size else { try respond(416, request: request); return }; start = offset
                    if !values[1].isEmpty {
                        guard let last = UInt64(values[1]), last >= start else { try respond(416, request: request); return }
                        end = min(last, attributes.size - 1) + 1
                    }
                }
                status = 206
            }
            let mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            var extra = "Content-Type: \(mime)\r\nAccept-Ranges: bytes\r\n"
            if status == 206 { extra += "Content-Range: bytes \(start)-\(end - 1)/\(attributes.size)\r\n" }
            try send(Data(responseHeader(status, length: end - start, extra: extra).utf8), request: request); started = true
            if first[0] == "HEAD" { return }
            while start < end {
                try cancellation.check()
                let limit = Int(min(1024 * 1024, end - start))
                let bytes: Data
                if let local { try local.seek(toOffset: start); bytes = try local.read(upToCount: limit) ?? Data() }
                else if let remoteHandle, let remote { bytes = try remote.read(remoteHandle, offset: start, length: limit) }
                else { throw WorkbenchError.message(L10n.text("预览读取通道不可用。")) }
                guard !bytes.isEmpty else { throw WorkbenchError.message(L10n.text("文件在预览期间变化。")) }
                try send(bytes, request: request); start += UInt64(bytes.count)
            }
        } catch { if !started && !cancellation.isCancelled { try? respond(404, request: request) } }
    }
    private func responseHeader(_ status: Int, length: UInt64, extra: String = "") -> String {
        let script = allowsScripts ? "'self' 'unsafe-inline'" : "'none'"
        let sandbox = allowsScripts ? "allow-scripts allow-same-origin" : "allow-same-origin"
        return "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Response")\r\nContent-Length: \(length)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nCross-Origin-Resource-Policy: same-origin\r\nContent-Security-Policy: default-src 'none'; script-src \(script); style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; media-src 'self'; connect-src 'self'; frame-src 'self'; base-uri 'self'; form-action 'none'; sandbox \(sandbox)\r\n\(extra)\r\n"
    }
    private func respond(_ status: Int, request: Request) throws { try send(Data(responseHeader(status, length: 0).utf8), request: request) }
    private func localReader(parts: [String]) throws -> FileHandle {
        var descriptor = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WorkbenchError.message(L10n.text("预览目录不可读。")) }
        for (index, part) in parts.enumerated() {
            let child = openat(descriptor, part, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (index == parts.count - 1 ? 0 : O_DIRECTORY))
            Darwin.close(descriptor)
            guard child >= 0 else { throw WorkbenchError.message(L10n.text("预览路径不安全或不可读。")) }; descriptor = child
        }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor); throw WorkbenchError.message(L10n.text("只允许预览普通文件。"))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private func send(_ data: Data, request: Request) throws {
        try request.cancellation.check()
        let sent = DispatchSemaphore(value: 0)
        request.connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { request.cancellation.cancel() }
            sent.signal()
        })
        let deadline = DispatchTime.now() + 15
        while sent.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            try request.cancellation.check()
            guard DispatchTime.now() < deadline else { throw WorkbenchError.message(L10n.text("浏览器读取超时。")) }
        }
        try request.cancellation.check()
    }
}
