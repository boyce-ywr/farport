import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkSFTPNames() throws {
    func entry(_ name: Data, longname: Data = Data()) -> Data {
        var packet = PacketWriter(); packet.bytes(name); packet.bytes(longname)
        packet.uint32(4); packet.uint32(0o100644)
        return packet.data
    }
    let invalid = Data([0x01, 0xe0, 0x14, 0x01, 0x40, 0x70, 0x71, 0x03, 0x40, 0x38, 0x0b, 0x40])
    var reader = PacketReader(entry(invalid, longname: invalid) + entry(Data("正常文件.txt".utf8), longname: invalid))
    try expect(try reader.directoryEntry(parent: "/fixture") == nil, "非 UTF8 文件名不替换成可操作假路径")
    let valid = try reader.directoryEntry(parent: "/fixture")
    try expect(valid?.name == "正常文件.txt" && valid?.path == "/fixture/正常文件.txt" && reader.remaining == 0, "跳过坏条目后继续解析，展示字段 longname 按字节忽略")
    for name in ["../escape", "bad\0name", "bad\nname", ""] {
        var parser = PacketReader(entry(Data(name.utf8)))
        try expect(try parser.directoryEntry(parent: "/fixture") == nil, "浏览时拒绝不安全条目")
    }
    var malformed = PacketReader(Data([0,0,0,50,1]))
    try rejects("坏条目不能掩盖包截断") { _ = try malformed.directoryEntry(parent: "/fixture") }
}

func checkDeviceFiles(arguments: [String]) throws {
    guard arguments.count == 3, let port = Int(arguments[1]) else { throw WorkbenchError.message("需要地址、端口、用户名") }
    let root = URL(fileURLWithPath: ".test/device-check").standardizedFileURL
    let paths = try ApplicationPaths(root: root)
    let known = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
    try Data(contentsOf: known).write(to: paths.knownHosts)
    let host = HostProfile(name: "设备只读检查", address: arguments[0], port: port, username: arguments[2])
    try paths.save([host], to: paths.hosts)
    let client = try SSHTransport(paths: paths, noninteractive: true).sftp(host); defer { client.close() }
    let home = try client.realpath()
    let result = try client.listForBrowsing(home)
    try expect(!result.files.isEmpty, "真实设备正常文件可列出")
    try expect(result.files.allSatisfy { !$0.name.contains("\u{fffd}") && $0.name.rangeOfCharacter(from: .controlCharacters) == nil }, "设备异常文件名不进入操作路径")
    if result.skipped > 0 { try rejects("真实设备递归操作不能静默忽略坏文件名") { _ = try client.list(home) } }
    print("PASS · 设备 SFTP 只读验证：显示 \(result.files.count) 项，明确跳过 \(result.skipped) 个异常文件名；未修改任何远端文件")
}
