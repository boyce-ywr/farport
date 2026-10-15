import Foundation
import AppKit
import CryptoKit
import Darwin
import WorkbenchCore
import OpenSSHBackend

setenv("FARPORT_LANGUAGE", "zh-Hans", 0)

signal(SIGPIPE, SIG_IGN)
setbuf(stdout, nil)
var checks = 0
func verify(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw WorkbenchError.message(message) }; checks += 1
}
func reject(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { checks += 1; return }; throw WorkbenchError.message(message)
}
func fixtureImage(_ url: URL) throws -> String {
    let code = String(Int.random(in: 10000...99999))
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 500, pixelsHigh: 220, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 500, height: 220).fill()
    NSColor.systemTeal.setFill(); NSBezierPath(ovalIn: NSRect(x: 24, y: 80, width: 65, height: 65)).fill()
    ("FARPORT " + code as NSString).draw(at: NSPoint(x: 110, y: 93), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 37, weight: .bold), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    try image.representation(using: .png, properties: [:])!.write(to: url)
    return code
}

do {
    let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".test/app").standardizedFileURL
    if CommandLine.arguments.contains("--tmux-path") { try checkRemoteTmuxPath(root: root); exit(0) }
    let paths = try ApplicationPaths(root: root)
    let hosts = try paths.load([HostProfile].self, from: paths.hosts)
    guard let remote = hosts.first, remote.address == "127.0.0.1", remote.port == 22281 else { throw WorkbenchError.message("仅允许隔离 SSH 测试主机") }
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let runID = UUID().uuidString.lowercased()
    let directory = root.deletingLastPathComponent().appendingPathComponent("attachments-" + runID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let picture = directory.appendingPathComponent("reference.png")
    let code = try fixtureImage(picture)
    let textFile = directory.appendingPathComponent("带空格 ' 引号.txt")
    let content = Data("Farport attachment verification\n".utf8)
    try content.write(to: textFile)
    let folder = directory.appendingPathComponent("folder"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try content.write(to: folder.appendingPathComponent("nested.txt"))
    let imageData = try Data(contentsOf: picture)
    let expectedHash = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
    let uploader = AttachmentUploader(transport: transport)
    var remoteUpload: UploadedAttachments?
    for host in [nil, remote] as [HostProfile?] {
        let client = try transport.files(host); defer { client.close() }
        let destination = try uploader.temporaryDirectory(host: host)
        let result = try uploader.upload([picture, textFile, folder], host: host, directory: destination, cancellation: CancellationFlag()) { _, _ in }
        try verify(result.paths.count == 3 && result.fileCount == 3, "附件数目不正确")
        try verify(client.preview(result.paths[0], offset: 0, limit: imageData.count) == imageData, "目标图片内容不一致")
        try verify(client.preview(result.paths[1]) == content, "特殊文件名内容不一致")
        try verify(client.stat(result.directory).permissions & 0o777 == 0o700, "附件目录非私有")
        try verify(client.stat(result.paths[0]).permissions & 0o777 == 0o600, "附件权限非私有")
        if host != nil { remoteUpload = result; try verify(!result.paths[0].hasPrefix(directory.path), "将本机路径误当远端路径") }
        try verify(result.directory.hasPrefix(destination + "/.farport-attachments-"), "未使用目标机器的临时目录")
        print("PASS · \(host == nil ? "本机" : "SSH") 图片、文件和目录上传、回读、权限与目标路径")
    }
    let cancelled = CancellationFlag(); cancelled.cancel()
    try reject("取消未阻止上传") { _ = try uploader.upload([picture], host: remote, directory: "/home/tester", cancellation: cancelled) { _, _ in } }
    try reject("权限不足未失败") { _ = try uploader.upload([picture], host: remote, directory: "/root", cancellation: CancellationFlag()) { _, _ in } }
    try reject("不存在文件未失败") { _ = try uploader.upload([directory.appendingPathComponent("missing")], host: remote, directory: "/home/tester", cancellation: CancellationFlag()) { _, _ in } }
    try reject("重复文件名未失败") { _ = try uploader.upload([picture, URL(fileURLWithPath: "/tmp/reference.png")], host: remote, directory: "/home/tester", cancellation: CancellationFlag()) { _, _ in } }
    print("PASS · 上传取消、权限不足、源不存在和命名冲突不返回附件引用")

    for host in [nil, remote] as [HostProfile?] {
        let service = TmuxService(transport: transport, host: host, socketName: "farport-check-" + runID)
        defer { _ = try? service.execute("kill-server") }
        try service.create(name: "work")
        guard let session = try service.sessions().first else { throw WorkbenchError.message("tmux 创建失败") }
        try service.rename(session: session.id, name: "renamed")
        try verify(service.sessions().first?.name == "renamed", "tmux 改名失败")
        let captured = try service.target(session: session.id)
        try service.createWindow(session: session.id)
        try reject("切换窗格后仍然发送") { try service.paste("do-not-send", session: session.id, expected: captured) }
        let pane = try service.panes().first { $0.id == captured.paneID }!
        try service.select(pane: pane)
        let before = try service.target(session: session.id)
        try service.paste("FARPORT_NO_ENTER", session: session.id, expected: before)
        let screen = try service.execute("capture-pane -p -t \(RemotePath.quote(before.paneID))").checked().text
        try verify(screen.contains("FARPORT_NO_ENTER"), "tmux 未收到文字")
        try verify(!screen.contains("command not found"), "插入附件时不应自动回车")
        try service.kill(session: session.id)
        try verify(service.sessions().isEmpty, "tmux 会话删除失败")
        print("PASS · \(host == nil ? "本机" : "远端") tmux 管理、定向粘贴、窗格变化拒绝、不自动回车")
    }
    guard let result = remoteUpload else { throw WorkbenchError.message("缺少远端附件结果") }
    let receiver = TmuxService(transport: transport, host: remote, socketName: "farport-agent-" + runID)
    defer { _ = try? receiver.execute("kill-server") }
    let proofPath = result.directory + "/receiver-proof.json"
    let python = "import sys,shlex,json,hashlib; from pathlib import Path; paths=shlex.split(sys.stdin.readline()); image=Path(paths[0]).read_bytes(); Path(\(String(reflecting: proofPath))).write_text(json.dumps({'path':paths[0],'sha256':hashlib.sha256(image).hexdigest(),'png':image[:8]==bytes([137,80,78,71,13,10,26,10]),'file':Path(paths[1]).read_text()})); import time; time.sleep(5)"
    _ = try receiver.execute("new-session -d -s reader \(RemotePath.quote("python3 -c " + RemotePath.quote(python)))").checked()
    Thread.sleep(forTimeInterval: 0.3)
    let receivingPane = try receiver.target(session: "reader")
    try receiver.paste(AttachmentReference.text(paths: Array(result.paths.prefix(2))), session: "reader", expected: receivingPane)
    let client = try transport.sftp(remote); defer { client.close() }
    try verify(client.statIfExists(proofPath) == nil, "接收程序不应在用户提交前收到完整行")
    _ = try receiver.execute("send-keys -t \(RemotePath.quote(receivingPane.paneID)) Enter").checked()
    for _ in 0..<50 { if try client.statIfExists(proofPath) != nil { break }; Thread.sleep(forTimeInterval: 0.1) }
    let proof = try JSONSerialization.jsonObject(with: client.preview(proofPath)) as! [String: Any]
    try verify(proof["sha256"] as? String == expectedHash && proof["png"] as? Bool == true, "远端窗格进程不能实际读取图片")
    try verify(proof["file"] as? String == String(decoding: content, as: UTF8.self), "远端窗格进程不能实际读取附件")
    let report: [String: Any] = ["checks": checks, "date": ISO8601DateFormatter().string(from: Date()), "localImage": picture.path,
                               "remoteImage": result.paths[0], "expectedImageCode": code, "remoteReadProof": proof,
                               "agentSemanticRecognition": "not-yet-verified"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.deletingLastPathComponent().appendingPathComponent("attachment-report.json"))
    print("PASS · \(checks) 项附件/tmux 断言；远端 tmux 中的独立进程已读到图片与文件。Agent 图片语义识别尚需单独验证。")
} catch { fputs("FAIL · \(error.localizedDescription)\n", stderr); exit(1) }
