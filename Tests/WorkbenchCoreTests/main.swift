import Foundation
import WorkbenchCore
import OpenSSHBackend

var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    checks += 1
    if try !condition() { throw WorkbenchError.message("断言失败：\(message)") }
}
func rejects(_ message: String, _ operation: () throws -> Void) throws {
    checks += 1
    do { try operation() } catch { return }
    throw WorkbenchError.message("未拒绝非法输入：\(message)")
}

do {
    let left = UUID(); let right = UUID(); let third = UUID()
    var layout = TerminalLayout(); layout.select(left); layout.split(with: right)
    layout.select(right)
    try expect(layout.primary == left && layout.secondary == right && layout.focused == right, "点击右侧标签保留分屏")
    layout.select(left)
    try expect(layout.primary == left && layout.secondary == right && layout.focused == left, "点击左侧标签保留分屏")
    layout.select(third)
    try expect(layout.primary == third && layout.secondary == right, "新终端替换焦点窗格而非拆除分屏")
    layout.close(third, fallback: nil)
    try expect(layout.primary == right && layout.secondary == nil, "关闭左窗格后保留右窗格")
    let localSources = [FileEndpoint(path: "/source/文件.txt"), FileEndpoint(path: "/source/folder")]
    let batch = try TransferBatch.jobs(sources: localSources, destinationDirectory: FileEndpoint(path: "/destination"))
    try expect(batch.count == 2 && batch[1].destination.path == "/destination/folder", "批量文件及目录保留名称")
    try expect(try TransferBatch.jobs(sources: localSources + [localSources[0]], destinationDirectory: FileEndpoint(path: "/destination")).count == 2, "多选重复项只复制一次")
    try expect(try TransferBatch.jobs(sources: [FileEndpoint(path: "/source/folder"), FileEndpoint(path: "/source/folder/child")], destinationDirectory: FileEndpoint(path: "/destination")).count == 1, "多选父目录时不重复子项")
    try rejects("同目录复制") { _ = try TransferBatch.jobs(sources: localSources, destinationDirectory: FileEndpoint(path: "/source")) }
    try rejects("子目录循环复制") { _ = try TransferBatch.jobs(sources: [localSources[1]], destinationDirectory: FileEndpoint(path: "/source/folder/child")) }
    try rejects("规范化后的原位置") { _ = try TransferBatch.jobs(sources: localSources, destinationDirectory: FileEndpoint(path: "/source/other/..")) }
    try rejects("不同源同名条目") { _ = try TransferBatch.jobs(sources: [FileEndpoint(path: "/one/a"), FileEndpoint(path: "/two/a")], destinationDirectory: FileEndpoint(path: "/destination")) }
    try rejects("空批次") { _ = try TransferBatch.jobs(sources: [], destinationDirectory: FileEndpoint(path: "/destination")) }
    try rejects("根目录") { _ = try TransferBatch.jobs(sources: [FileEndpoint(path: "/")], destinationDirectory: FileEndpoint(path: "/destination")) }
    let remoteID = UUID()
    try expect(try TransferBatch.jobs(sources: localSources, destinationDirectory: FileEndpoint(hostID: remoteID, path: "/source")).count == 2, "不同主机允许相同路径")
    var writer = PacketWriter(); writer.uint64(UInt64.max); writer.string("文件 \" ' 😀")
    var reader = PacketReader(writer.data)
    try expect(reader.uint64() == UInt64.max, "64 位整数往返")
    try expect(reader.string() == "文件 \" ' 😀", "Unicode 和引号往返")
    try expect(reader.remaining == 0, "完整消费数据包")
    for count in 0..<4 {
        try rejects("截断头部 \(count)") { var packet = PacketReader(Data(repeating: 0, count: count)); _ = try packet.uint32() }
    }
    try rejects("超长字段") { var packet = PacketReader(Data([255, 255, 255, 255])); _ = try packet.string() }
    try rejects("非法 UTF-8") { var packet = PacketReader(Data([0, 0, 0, 1, 255])); _ = try packet.string() }
    try expect(RemotePath.join("/", "file") == "/file", "根目录拼接")
    try expect(RemotePath.join("/home/user/", "文件") == "/home/user/文件", "目录拼接")
    try expect(RemotePath.parent("/file") == "/", "父目录")
    for name in ["", ".", "..", "../file", "a/b", "a\0b", "a\nb"] { try expect(!RemotePath.validName(name), "文件名校验") }
    for address in ["-oProxyCommand=sh", "a b", "foo\nbar", "user@host", "/bin/sh", ""] {
        try rejects("主机地址 \(address)") { try HostProfile(name: "invalid", address: address).validate() }
    }
    try HostProfile(name: "IPv6", address: "::1", username: "user").validate()
    try rejects("无效端口") { try HostProfile(name: "host", address: "localhost", port: 0).validate() }
    try rejects("用户名选项注入") { try HostProfile(name: "host", address: "localhost", username: "-root").validate() }
    let quoted = "hello'; printf injected; echo '"
    let result = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "printf '%s' \(RemotePath.quote(quoted))"]).checked()
    try expect(result.text == quoted, "shell 引号阻止命令注入")
    let job = TransferJob(source: FileEndpoint(path: "/tmp/a"), destination: FileEndpoint(hostID: UUID(), path: "/tmp/b"))
    let restored = try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job))
    try expect(restored.id == job.id && restored.source == job.source, "断点清单往返")
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("farport-core-" + UUID().uuidString)
    let paths = try ApplicationPaths(root: temporaryRoot)
    defer { try? FileManager.default.removeItem(at: temporaryRoot); try? FileManager.default.removeItem(at: paths.sockets) }
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let originalHost = HostProfile(name: "fixture", address: "127.0.0.1", username: "tester")
    let options = try transport.options(for: originalHost)
    let control = options.first { $0.hasPrefix("ControlPath=") }!
    let expandedLength = control.dropFirst("ControlPath=".count).replacingOccurrences(of: "%C", with: String(repeating: "a", count: 40)).utf8.count
    try expect(expandedLength + 17 < 104, "socket 路径为随机后缀预留空间")
    var modifiedHost = originalHost; modifiedHost.port = 2222
    let changedOptions = try transport.options(for: modifiedHost)
    try expect(changedOptions.first { $0.hasPrefix("ControlPath=") } != control, "编辑端口隔离连接复用")
    let cancelled = CancellationFlag(); cancelled.cancel()
    try rejects("取消标记") { try cancelled.check() }
    for length in 0..<512 {
        let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var packet = PacketWriter(); packet.bytes(data); var parsed = PacketReader(packet.data)
        try expect(parsed.bytes() == data, "二进制字段往返 \(length)")
    }
    print("PASS · \(checks) 项核心断言")
} catch {
    fputs("FAIL · \(error.localizedDescription)\n", stderr)
    exit(1)
}
