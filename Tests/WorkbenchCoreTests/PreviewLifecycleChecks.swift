import Foundation
import Darwin
import WorkbenchCore
import OpenSSHBackend

private final class PreviewSocket {
    let descriptor: Int32
    init(port: UInt16) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WorkbenchError.message("无法创建预览回归套接字") }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(descriptor); throw WorkbenchError.message("预览回归连接失败") }
    }
    deinit { Darwin.close(descriptor) }
    func send(_ request: String) throws {
        let data = Data(request.utf8)
        let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw WorkbenchError.message("预览回归请求未发送完整") }
    }
    func read(timeout: Int32 = 2000) throws -> Data {
        var descriptor = pollfd(fd: self.descriptor, events: Int16(POLLIN), revents: 0)
        let started = Date()
        let deadline = started.addingTimeInterval(Double(timeout) / 1000)
        while true {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            let result = poll(&descriptor, 1, remaining)
            if result > 0 { break }
            if result < 0 && errno == EINTR && Date() < deadline { continue }
            throw WorkbenchError.message("预览回归读取超时/失败：等待 \(Date().timeIntervalSince(started)) 秒，poll=\(result)，errno=\(errno)")
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = recv(self.descriptor, &bytes, bytes.count, 0)
        if count < 0, errno == ECONNRESET { return Data() }
        guard count >= 0 else { throw WorkbenchError.message("预览回归读取失败") }
        return Data(bytes.prefix(count))
    }
}

private final class WeakPreviewServer {
    weak var value: FilePreviewServer?
    init(_ server: FilePreviewServer) { value = server }
}

func checkPreviewResourceConnections() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farport-html-connections-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("<html>relative resources</html>".utf8).write(to: root.appendingPathComponent("index.html"))
    let server = try FilePreviewServer(transport: SSHTransport(paths: try ApplicationPaths(root: root.appendingPathComponent("config"))), host: nil, directory: root.path)
    defer { server.stop() }
    var sockets: [PreviewSocket] = []
    for _ in 0..<6 { sockets.append(try PreviewSocket(port: server.port)) }
    Thread.sleep(forTimeInterval: 0.1)
    let path = try server.url(for: "index.html").path
    for socket in sockets {
        try socket.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n")
    }
    for (index, socket) in sockets.enumerated() {
        try expect(try String(decoding: socket.read(timeout: 5000), as: UTF8.self).hasPrefix("HTTP/1.1 200"), "HTML 同时请求六个关联资源时不应丢弃请求：\(index + 1)")
    }
    print("PASS · HTML 六路同时连接的资源请求全部完成")
}

func checkPreviewLifecycle() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("farport-preview-lifecycle-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let media = folder.appendingPathComponent("video.mp4")
    FileManager.default.createFile(atPath: media.path, contents: nil)
    let file = try FileHandle(forWritingTo: media); try file.truncate(atOffset: 64 * 1024 * 1024); try file.close()
    let paths = try ApplicationPaths(root: folder.appendingPathComponent("config"))
    defer { try? FileManager.default.removeItem(at: paths.sockets) }
    let transport = SSHTransport(paths: paths)
    for iteration in 0..<50 {
        var server: FilePreviewServer? = try FilePreviewServer(transport: transport, host: nil, directory: folder.path, fileName: "video.mp4")
        let released = WeakPreviewServer(server!)
        let port = server!.port
        let path = try server!.url(for: "video.mp4").path
        var sockets: [PreviewSocket] = []
        for _ in 0..<4 {
            let client = try PreviewSocket(port: port)
            try client.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nRange: bytes=0-\r\n\r\n")
            let response = try client.read()
            try expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 206"), "实际开始媒体传输后关闭服务")
            sockets.append(client)
        }
        let overflow = try PreviewSocket(port: port)
        try overflow.send("HEAD \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        if iteration.isMultiple(of: 2) {
            sockets.removeFirst()
            try expect(try String(decoding: overflow.read(timeout: 5000), as: UTF8.self).hasPrefix("HTTP/1.1 200"), "读取槽位释放后队列中的关联资源继续读取")
        }
        if iteration.isMultiple(of: 10) { print("预览生命周期回归：第 \(iteration + 1) 轮，4 个媒体请求已开始"); fflush(stdout) }
        server!.stop(); server!.stop(); server = nil
        if !iteration.isMultiple(of: 2) { try expect(try overflow.read().isEmpty, "停止预览同时关闭排队请求") }
        let deadline = Date().addingTimeInterval(4)
        while released.value != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try expect(released.value == nil, "停止后服务及时释放，不等待120秒超时")
        sockets.removeAll()
    }
    for _ in 0..<20 {
        var server: FilePreviewServer? = try FilePreviewServer(transport: transport, host: nil, directory: folder.path)
        let released = WeakPreviewServer(server!)
        let port = server!.port
        let path = try server!.url(for: "video.mp4").path
        let partial = try PreviewSocket(port: port)
        try partial.send("GET \(path) HTTP/1.1\r\nHost:")
        let validation = try PreviewSocket(port: port)
        try validation.send("HEAD \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        try expect(try String(decoding: validation.read(), as: UTF8.self).hasPrefix("HTTP/1.1 200"), "半包请求不阻塞其他请求")
        Thread.sleep(forTimeInterval: 0.03)
        server = nil
        let deadline = Date().addingTimeInterval(2)
        while released.value != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try expect(released.value == nil, "未手动stop时半包连接也能释放服务")
        try expect(try partial.read().isEmpty, "析构关闭未完成请求")
    }
    let server = try FilePreviewServer(transport: transport, host: nil, directory: folder.path)
    defer { server.stop() }
    let port = server.port
    let path = try server.url(for: "video.mp4").path
    for _ in 0..<20 {
        for invalid in ["GET / HTTP/1.1\r\n", "GET / HTTP/1.1\r\nX-Fill: " + String(repeating: "a", count: 18000)] {
            let broken = try PreviewSocket(port: port)
            try broken.send(invalid)
            shutdown(broken.descriptor, SHUT_WR)
            try expect(try broken.read().isEmpty, "超大或不完整请求被关闭")
        }
        let valid = try PreviewSocket(port: port)
        try valid.send("HEAD \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        try expect(try String(decoding: valid.read(), as: UTF8.self).hasPrefix("HTTP/1.1 200"), "异常断连后限流槽位可复用")
    }
    for _ in 0..<30 {
        let raced = try FilePreviewServer(transport: transport, host: nil, directory: folder.path)
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            if index.isMultiple(of: 3) { raced.stop() }
            else if let socket = try? PreviewSocket(port: raced.port) { try? socket.send("GET / HTTP/1.1\r\n") }
        }
        try expect(!raced.isRunning, "接入与并发stop后服务保持停止")
        try rejects("停止后不得生成新预览链接") { _ = try raced.url(for: "video.mp4") }
    }
    print("PASS · 50轮并发媒体关闭、20轮半包析构、20轮异常连接恢复、30轮接入/停止竞态")
}

func checkPreviewTimeout() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("farport-preview-timeout-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("preview".utf8).write(to: folder.appendingPathComponent("index.html"))
    let paths = try ApplicationPaths(root: folder.appendingPathComponent("config"))
    defer { try? FileManager.default.removeItem(at: paths.sockets) }
    let server = try FilePreviewServer(transport: SSHTransport(paths: paths), host: nil, directory: folder.path)
    defer { server.stop() }
    let clients = try (0..<4).map { _ -> PreviewSocket in
        let client = try PreviewSocket(port: server.port)
        try client.send("GET / HTTP/1.1\r\n")
        return client
    }
    print("开始等待真实 120 秒请求超时"); fflush(stdout)
    for client in clients { try expect(try client.read(timeout: 140000).isEmpty, "空闲预览连接超时关闭") }
    let url = try server.url(for: "index.html")
    let client = try PreviewSocket(port: server.port)
    try client.send("GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n")
    try expect(try String(decoding: client.read(), as: UTF8.self).hasPrefix("HTTP/1.1 200"), "超时后四个槽位均不泄漏")
    print("PASS · 真实120秒超时后预览服务仍可接受请求")
}

func checkRemotePreviewLifecycle(root: String) throws {
    let paths = try ApplicationPaths(root: URL(fileURLWithPath: root))
    let hosts = try paths.load([HostProfile].self, from: paths.hosts)
    guard let host = hosts.first, host.address == "127.0.0.1", [22281, 22282].contains(host.port) else { throw WorkbenchError.message("远端预览生命周期仅允许隔离 SSH 节点") }
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let directory = "/tmp/farport-preview-lifecycle-" + UUID().uuidString
    let client = try transport.sftp(host)
    defer { client.close() }
    try client.mkdir(directory)
    defer { try? client.removeRecursively(directory) }
    let handle = try client.openWrite(directory + "/video.mp4", exclusive: true)
    try client.write(handle, offset: 64 * 1024 * 1024 - 1, data: Data([0])); try client.closeHandle(handle)
    for iteration in 0..<10 {
        var server: FilePreviewServer? = try FilePreviewServer(transport: transport, host: host, directory: directory, fileName: "video.mp4")
        let released = WeakPreviewServer(server!)
        let port = server!.port
        let path = try server!.url(for: "video.mp4").path
        var clients: [PreviewSocket] = []
        for _ in 0..<4 {
            let socket = try PreviewSocket(port: port)
            try socket.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nRange: bytes=0-\r\n\r\n")
            try expect(try String(decoding: socket.read(timeout: 10000), as: UTF8.self).hasPrefix("HTTP/1.1 206"), "SSH 媒体开始读取")
            clients.append(socket)
        }
        if iteration.isMultiple(of: 2) { clients.removeAll() }
        server!.stop(); server = nil
        let deadline = Date().addingTimeInterval(4)
        while released.value != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try expect(released.value == nil, "SSH 请求取消后读取任务与服务及时释放")
        clients.removeAll()
    }
    print("PASS · 10轮隔离SSH并发媒体读取、客户端断开、停止服务与释放")
}
