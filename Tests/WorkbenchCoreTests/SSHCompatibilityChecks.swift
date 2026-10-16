import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkSSHCompatibility() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farport-ssh-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let diagnostic = root.appendingPathComponent("diagnostic.bin")
    let bytes: [UInt8] = [0xcf, 0xb5, 0xcd, 0xb3, 0xd5, 0xd2, 0xb2, 0xbb, 0xb5, 0xbd, 0xd6, 0xb8, 0xb6, 0xa8, 0xb5, 0xc4, 0xc2, 0xb7, 0xbe, 0xb6, 0xa1, 0xa3]
    try Data(bytes).write(to: diagnostic)
    let result = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "cat \(RemotePath.quote(diagnostic.path)) >&2; exit 1"])
    try expect(result.error == "系统找不到指定的路径。", "Windows CP936 错误信息无乱码")
    try expect(CommandDiagnostic.decode(Data("中文 ✓".utf8)) == "中文 ✓", "UTF-8 错误保持原样")
    try expect(CommandDiagnostic.decode(Data([0xff, 0xfe]) + "错误".data(using: .utf16LittleEndian)!) == "错误", "识别 UTF-16 BOM 错误")
    let probe = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", SSHTransport.connectionProbe])
    try expect(probe.status == 0 && probe.text.contains("FARPORT_SSH_READY") && !SSHTransport.connectionProbe.contains("true"), "跨平台 SSH 探测不依赖 true")
    let binary = try ProcessRunner.run(executable: "/bin/cat", arguments: [diagnostic.path])
    try expect(binary.output == Data(bytes), "错误解码不影响二进制标准输出")
}
