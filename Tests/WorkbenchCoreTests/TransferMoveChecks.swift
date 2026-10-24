import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkTransferMoves() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farport-move-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = TransferEngine(transport: SSHTransport(paths: try ApplicationPaths(root: root.appendingPathComponent("config"))))
    let source = root.appendingPathComponent("source ' 中文.txt")
    let destination = root.appendingPathComponent("target ' 中文.txt")
    let content = Data("native file operations\n".utf8)
    try content.write(to: source)
    let copied = engine.execute(TransferJob(source: FileEndpoint(path: source.path), destination: FileEndpoint(path: destination.path)), hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(copied.status == .completed && copied.message.contains("cp"), "同机复制使用原生 cp")
    try expect(try Data(contentsOf: source) == content && Data(contentsOf: destination) == content, "原生复制支持引号和中文，保留源文件")
    let guardedJob = TransferJob(source: FileEndpoint(path: source.path), destination: FileEndpoint(path: root.appendingPathComponent("guarded-copy").path))
    let unsafeStage = root.appendingPathComponent(".swb-" + guardedJob.id.uuidString + ".copy")
    try FileManager.default.createSymbolicLink(at: unsafeStage, withDestinationURL: root)
    let guarded = engine.execute(guardedJob, hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(guarded.status == .failed && !FileManager.default.fileExists(atPath: root.appendingPathComponent("payload").path), "原生 cp 拒绝符号链接暂存目录")
    try FileManager.default.removeItem(at: unsafeStage)
    let originalInode = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
    let move = TransferJob(source: FileEndpoint(path: source.path), destination: FileEndpoint(path: destination.path), operation: .move)
    let conflict = engine.execute(move, hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(conflict.status == .awaitingConfirmation && FileManager.default.fileExists(atPath: source.path), "剪切粘贴冲突确认前源文件不移动")
    var approved = conflict; approved.approvedConflicts = conflict.conflicts
    let moved = engine.execute(approved, hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(moved.status == .completed && moved.message.contains("mv"), "同机移动使用原生 mv")
    try expect(!FileManager.default.fileExists(atPath: source.path) && Data(contentsOf: destination) == content, "移动成功后源消失、目标内容正确")
    try expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber == originalInode, "同文件系统原生移动保留 inode 而非复制重写")

    let from = root.appendingPathComponent("tree"); let to = root.appendingPathComponent("moved-tree")
    try FileManager.default.createDirectory(at: from.appendingPathComponent("empty"), withIntermediateDirectories: true)
    try content.write(to: from.appendingPathComponent(".hidden"))
    let tree = engine.execute(TransferJob(source: FileEndpoint(path: from.path), destination: FileEndpoint(path: to.path), operation: .move), hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(tree.status == .completed && tree.nativeMove == true && !FileManager.default.fileExists(atPath: from.path), "目录整棵树通过原生 mv 移动")
    try expect(FileManager.default.fileExists(atPath: to.appendingPathComponent("empty").path) && Data(contentsOf: to.appendingPathComponent(".hidden")) == content, "目录移动包含空目录和隐藏文件")

    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: to)
    let recursive = engine.execute(TransferJob(source: FileEndpoint(path: to.path), destination: FileEndpoint(path: alias.appendingPathComponent("child").path), operation: .move), hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(recursive.status == .failed && FileManager.default.fileExists(atPath: to.path), "通过符号链接复制到自身子目录仍被拒绝")
    let identical = engine.execute(TransferJob(source: FileEndpoint(path: to.appendingPathComponent(".hidden").path), destination: FileEndpoint(path: alias.appendingPathComponent(".hidden").path)), hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(identical.status == .failed, "不同文本路径指向同一文件时拒绝操作")

    let stageSource = root.appendingPathComponent("stage-source"); let stageTarget = root.appendingPathComponent("stage-target")
    try content.write(to: stageSource)
    let flag = CancellationFlag()
    let paused = engine.execute(TransferJob(source: FileEndpoint(path: stageSource.path), destination: FileEndpoint(path: stageTarget.path), operation: .move), hosts: [], cancellation: flag) { state in
        if state.nativeMove == true { flag.cancel() }
    }
    try expect(paused.status == .paused && FileManager.default.fileExists(atPath: stageSource.path), "原生命令执行前取消仍保留源文件")
    let staging = root.appendingPathComponent(".swb-" + paused.id.uuidString + ".move")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.moveItem(at: stageSource, to: staging.appendingPathComponent("payload"))
    let resumed = engine.execute(try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(paused)), hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(resumed.status == .completed && Data(contentsOf: stageTarget) == content, "源已进入暂存后可由持久化任务恢复落位")

    let mergeSource = root.appendingPathComponent("merge-source"); let mergeTarget = root.appendingPathComponent("merge-target")
    for directory in [mergeSource, mergeTarget] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    for name in ["a", "b"] { try content.write(to: mergeSource.appendingPathComponent(name)) }
    try Data("keep extra".utf8).write(to: mergeTarget.appendingPathComponent("extra"))
    let mergeJob = TransferJob(source: FileEndpoint(path: mergeSource.path), destination: FileEndpoint(path: mergeTarget.path), overwrite: true, operation: .move)
    let cleanupFlag = CancellationFlag()
    let partial = engine.execute(mergeJob, hosts: [], cancellation: cleanupFlag) { state in
        if state.entries.contains(where: { $0.sourceRemoved == true }) { cleanupFlag.cancel() }
    }
    try expect(partial.status == .paused && partial.entries.contains(where: { $0.sourceRemoved == true }), "目录合并移动可在部分删源后暂停")
    let merged = engine.execute(partial, hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(merged.status == .completed && !FileManager.default.fileExists(atPath: mergeSource.path), "部分删源的移动任务可继续完成")
    try expect(try String(contentsOf: mergeTarget.appendingPathComponent("extra"), encoding: .utf8) == "keep extra", "合并移动保留目标额外文件")

    for change in ["add", "corrupt"] {
        let folder = root.appendingPathComponent(change + "-source"); let target = root.appendingPathComponent(change + "-target")
        for directory in [folder, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        try content.write(to: folder.appendingPathComponent("data"))
        var altered = false
        let failure = engine.execute(TransferJob(source: FileEndpoint(path: folder.path), destination: FileEndpoint(path: target.path), overwrite: true, operation: .move), hosts: [], cancellation: CancellationFlag()) { state in
            guard !altered, state.entries.allSatisfy(\.finished), !state.entries.isEmpty else { return }
            altered = true
            if change == "add" { try? content.write(to: folder.appendingPathComponent("new")) }
            else {
                let file = target.appendingPathComponent("data")
                let date = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
                try? Data(repeating: 42, count: content.count).write(to: file)
                if let date { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path) }
            }
        }
        try expect(failure.status == .failed && FileManager.default.fileExists(atPath: folder.appendingPathComponent("data").path), "新增源条目或同长度目标损坏时禁止删源：" + change)
    }
    let local = FileEndpoint(path: "/tmp/a")
    let host = HostProfile(name: "host", address: "127.0.0.1", port: 22281, username: "tester")
    var equivalent = host; equivalent.id = UUID(); equivalent.name = "another label"
    var different = host; different.id = UUID(); different.port = 22282
    let hosts = [host, equivalent, different]
    try expect(FileEndpoint(hostID: host.id, path: "/a").isSameMachine(as: FileEndpoint(hostID: equivalent.id, path: "/b"), hosts: hosts), "不同标签但相同连接端点识别为同机")
    try expect(!FileEndpoint(hostID: host.id, path: "/a").isSameMachine(as: FileEndpoint(hostID: different.id, path: "/b"), hosts: hosts), "同 IP 不同 SSH 端口不识别为同机")
    try expect(!local.isSameMachine(as: FileEndpoint(hostID: host.id, path: "/a"), hosts: hosts), "本机与 loopback SSH 端点不混淆")
    let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(move)) as! [String: Any]
    let legacyData = try JSONSerialization.data(withJSONObject: legacy.filter { !["operation", "nativeMove"].contains($0.key) })
    try expect(try !JSONDecoder().decode(TransferJob.self, from: legacyData).isMove, "旧传输记录缺少操作字段时仍为复制")
    print("PASS · 原生 cp/mv、inode、目录、引用路径、冲突、暂停恢复、内容校验与删源保护")
}

func checkTransferMovesSSH(root: String) throws {
    let paths = try ApplicationPaths(root: URL(fileURLWithPath: root))
    let hosts = try JSONDecoder().decode([HostProfile].self, from: Data(contentsOf: paths.root.appendingPathComponent("hosts.json")))
    guard let first = hosts.first(where: { $0.address == "127.0.0.1" && $0.port == 22281 }),
          let second = hosts.first(where: { $0.address == "127.0.0.1" && $0.port == 22282 }) else { throw WorkbenchError.message("仅允许隔离 SSH 测试主机") }
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let engine = TransferEngine(transport: transport)
    let clients = try [transport.sftp(first), transport.sftp(second)]
    let directory = "/tmp/farport-move-" + UUID().uuidString
    for client in clients { try client.mkdir(directory) }
    defer { for client in clients { try? client.removeRecursively(directory); client.close() } }
    let content = Data((0..<(1024 * 1024 + 9)).map { UInt8(truncatingIfNeeded: $0) })
    let source = directory + "/source ' 中文"
    try clients[0].createFile(source); try clients[0].saveText(source, data: content, expected: clients[0].stat(source), original: Data())
    var alias = first; alias.id = UUID(); alias.name = "same endpoint alias"
    let profiles = hosts + [alias]
    let copied = engine.execute(TransferJob(source: FileEndpoint(hostID: first.id, path: source), destination: FileEndpoint(hostID: alias.id, path: directory + "/copy")), hosts: profiles, cancellation: CancellationFlag()) { _ in }
    try expect(copied.status == .completed && copied.message.contains("cp"), "相同连接的不同主机记录走远端原生 cp")
    let moved = engine.execute(TransferJob(source: FileEndpoint(hostID: alias.id, path: directory + "/copy"), destination: FileEndpoint(hostID: first.id, path: directory + "/move"), operation: .move), hosts: profiles, cancellation: CancellationFlag()) { _ in }
    try expect(moved.status == .completed && moved.message.contains("mv") && clients[0].statIfExists(directory + "/copy") == nil, "远端同机原生 mv 成功并移除源")
    let cross = engine.execute(TransferJob(source: FileEndpoint(hostID: first.id, path: source), destination: FileEndpoint(hostID: second.id, path: directory + "/cross"), operation: .move), hosts: hosts, cancellation: CancellationFlag()) { _ in }
    try expect(cross.status == .completed && cross.nativeMove != true, "不同 SSH 端口使用跨机校验移动而非 mv")
    try expect(try clients[0].statIfExists(source) == nil && clients[1].preview(directory + "/cross", limit: content.count) == content, "跨机完整校验后删源且目标字节一致")
    let folder = directory + "/folder"
    try clients[0].mkdir(folder); try clients[0].mkdir(folder + "/empty")
    try clients[0].createFile(folder + "/.hidden")
    try clients[0].saveText(folder + "/.hidden", data: content, expected: clients[0].stat(folder + "/.hidden"), original: Data())
    let folderMove = engine.execute(TransferJob(source: FileEndpoint(hostID: first.id, path: folder), destination: FileEndpoint(hostID: second.id, path: folder), operation: .move), hosts: hosts, cancellation: CancellationFlag()) { _ in }
    try expect(folderMove.status == .completed && clients[0].statIfExists(folder) == nil && clients[1].stat(folder + "/empty").isDirectory, "跨机目录移动保留空目录并清理源目录")
    try expect(try clients[1].preview(folder + "/.hidden", limit: content.count) == content, "跨机目录移动包含隐藏文件且内容正确")
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("farport-download-move-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: local) }
    let download = engine.execute(TransferJob(source: FileEndpoint(hostID: second.id, path: directory + "/cross"), destination: FileEndpoint(path: local.path), operation: .move), hosts: hosts, cancellation: CancellationFlag()) { _ in }
    try expect(download.status == .completed && Data(contentsOf: local) == content && clients[1].statIfExists(directory + "/cross") == nil, "SSH 移动至 Mac 校验后删远端源")
    let upload = engine.execute(TransferJob(source: FileEndpoint(path: local.path), destination: FileEndpoint(hostID: second.id, path: directory + "/upload"), operation: .move), hosts: hosts, cancellation: CancellationFlag()) { _ in }
    try expect(upload.status == .completed && !FileManager.default.fileExists(atPath: local.path) && clients[1].preview(directory + "/upload", limit: content.count) == content, "Mac 移动至 SSH 校验后删本机源")
    print("PASS · 隔离 SSH 同机原生 cp/mv、同 IP 不同端口跨机移动、内容校验及删源")
}
