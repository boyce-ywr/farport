import Foundation
import Darwin
import WorkbenchCore
import OpenSSHBackend

private final class RelayCheckState {
    private let condition = NSCondition()
    private var port: Int?
    private var failure: String?
    private var children: [Process] = []
    func ready(_ value: Int) { condition.lock(); port = value; condition.broadcast(); condition.unlock() }
    func fail(_ value: String) { condition.lock(); failure = value; condition.broadcast(); condition.unlock() }
    func record(_ process: Process) { condition.lock(); children.append(process); condition.unlock() }
    var running: Bool { condition.lock(); defer { condition.unlock() }; return children.contains { $0.isRunning } }
    var lastFailure: String? { condition.lock(); defer { condition.unlock() }; return failure }
    func awaitPort() throws -> Int {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while port == nil && failure == nil { if !condition.wait(until: deadline) { break } }
        guard let port else { throw WorkbenchError.message(failure ?? "桌面通道未及时启动") }
        return port
    }
}

func checkScreenSharingSSH(root: String) throws {
    let paths = try ApplicationPaths(root: URL(fileURLWithPath: root))
    let hosts = try paths.load([HostProfile].self, from: paths.hosts)
    guard let host = hosts.first(where: { ["localhost", "127.0.0.1", "::1"].contains($0.address) && $0.jumpHost.isEmpty }) else {
        throw WorkbenchError.message("桌面SSH回归仅接受隔离的本机测试服务器")
    }
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let endpoint = try ScreenSharingEndpoint(host: "127.0.0.1", port: 22)
    let arguments = try transport.screenSharingArguments(for: host, endpoint: endpoint)
    let state = RelayCheckState()
    let relay = try ScreenSharingRelay(makeProcess: {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments; process.environment = transport.environment(for: host); state.record(process); return process
    }, ready: state.ready, failure: state.fail)
    defer { relay.stop() }
    let port = try state.awaitPort()
    let descriptor = try connectRelay(port: port)
    defer { Darwin.close(descriptor) }
    var banner = [UInt8](repeating: 0, count: 256)
    var receivedBanner = Data()
    while receivedBanner.count < 4 {
        let received = Darwin.read(descriptor, &banner, banner.count)
        guard received > 0 else { throw WorkbenchError.message(state.lastFailure ?? "真实SSH转发未返回目标服务标识") }
        receivedBanner.append(contentsOf: banner.prefix(received))
    }
    try expect(String(decoding: receivedBanner, as: UTF8.self).hasPrefix("SSH-"), "真实SSH认证后的stdio通道可到达隔离服务器目标端口")
    relay.stop()
    let deadline = Date().addingTimeInterval(3)
    while state.running && Date() < deadline { usleep(10000) }
    try expect(!state.running, "真实SSH桌面通道停止后子进程退出")
    print("PASS · 真实隔离SSH认证、目标端口转发与进程清理；不代表Mac桌面认证已验收")
}

func checkScreenSharing() throws {
    let endpoint = try ScreenSharingEndpoint(host: "2001:db8::1")
    try expect(endpoint.url?.absoluteString == "vnc://[2001:db8::1]:5900", "IPv6桌面URL与端口正确")
    try expect(endpoint.forwardingTarget == "[2001:db8::1]:5900", "IPv6 SSH stdio转发格式")
    for address in ["", "-host", "user@host", "vnc://host", "host/path", "host\n", "host?token", "host#x"] {
        try rejects("桌面地址不能注入凭据或URL参数") { _ = try ScreenSharingEndpoint(host: address) }
    }
    for port in [0, -1, 65536] { try rejects("桌面端口范围检查") { _ = try ScreenSharingEndpoint(host: "localhost", port: port) } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farport-desktop-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try ApplicationPaths(root: root)
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let host = HostProfile(name: "fixture", address: "mac.example", jumpHost: "gateway.example")
    let arguments = try transport.screenSharingArguments(for: host, endpoint: endpoint)
    try expect(arguments.contains("-W") && arguments.contains(endpoint.forwardingTarget) && arguments.contains("gateway.example"), "桌面复用跳板配置并以stdio转发，不执行远端Shell")
    try expect(arguments.contains("ControlPath=none") && arguments.contains("ClearAllForwardings=yes") && arguments.contains("ForwardAgent=no"), "桌面通道独立且不继承额外转发")
    let state = RelayCheckState()
    let relay = try ScreenSharingRelay(makeProcess: {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/cat"); state.record(process); return process
    }, ready: state.ready, failure: state.fail)
    defer { relay.stop() }
    let port = try state.awaitPort()
    let descriptor = try connectRelay(port: port)
    defer { Darwin.close(descriptor) }
    let payload = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
    for _ in 0..<64 {
        var written = 0
        while written < payload.count {
            let count = payload.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: written), payload.count - written) }
            guard count > 0 else { throw WorkbenchError.message("桌面写入未完成") }; written += count
        }
        var received = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while received.count < payload.count {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, payload.count - received.count))
            guard count > 0 else { throw WorkbenchError.message("桌面读取中断或超时") }; received.append(contentsOf: buffer.prefix(count))
        }
        try expect(received == payload, "桌面双向二进制流不截断或改写")
    }
    shutdown(descriptor, SHUT_WR)
    var finalByte: UInt8 = 0
    try expect(Darwin.read(descriptor, &finalByte, 1) == 0, "客户端半关闭后排空输出并关闭连接")
    relay.stop()
    let deadline = Date().addingTimeInterval(3)
    while state.running && Date() < deadline { usleep(10000) }
    try expect(!state.running, "停止桌面通道后无残留子进程")
    for _ in 0..<20 {
        let temporary = try ScreenSharingRelay(makeProcess: { Process() }, ready: { _ in }, failure: { _ in })
        temporary.stop()
    }
    print("PASS · 桌面loopback动态端口、512 KiB双向流、半关闭与20轮生命周期")
}

private func connectRelay(port: Int) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw WorkbenchError.message("无法创建桌面回归套接字") }
    var timeout = timeval(tv_sec: 15, tv_usec: 0); var enabled: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard connected == 0 else { Darwin.close(descriptor); throw WorkbenchError.message("无法连接loopback桌面端口") }
    return descriptor
}
