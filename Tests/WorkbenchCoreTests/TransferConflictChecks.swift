import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkTransferConflicts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farport-conflicts-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt"); let destination = root.appendingPathComponent("target.txt")
    try Data("new content".utf8).write(to: source); try Data("keep original".utf8).write(to: destination)
    let engine = TransferEngine(transport: SSHTransport(paths: try ApplicationPaths(root: root.appendingPathComponent("config"))))
    let result = engine.execute(TransferJob(source: FileEndpoint(path: source.path), destination: FileEndpoint(path: destination.path)), hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(result.status.rawValue == "awaitingConfirmation", "目标已存在时等待用户确认，而不是传输失败")
    try expect(try Data(contentsOf: destination) == Data("keep original".utf8), "确认前不覆盖目标")
    try expect(result.conflicts?.count == 1 && result.conflicts?.first?.canReplace == true, "冲突携带可替换的目标快照")
    let restored = try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(result))
    try expect(restored.conflicts == result.conflicts && restored.status == .awaitingConfirmation, "等待确认状态可持久化")
    var approved = result; approved.approvedConflicts = result.conflicts
    let completed = engine.execute(approved, hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(completed.status == .completed && Data(contentsOf: destination) == Data("new content".utf8), "确认后覆盖并完成")
    try Data("changed after approval".utf8).write(to: destination)
    let changed = engine.execute(approved, hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(changed.status == .awaitingConfirmation, "批准后目标快照变化必须再次确认")
    try FileManager.default.removeItem(at: destination)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    var overwrite = TransferJob(source: FileEndpoint(path: source.path), destination: FileEndpoint(path: destination.path), overwrite: true)
    let incompatible = engine.execute(overwrite, hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(incompatible.status == .awaitingConfirmation && incompatible.conflicts?.first?.canReplace == false, "类型不兼容不可强制覆盖")
    try FileManager.default.removeItem(at: destination)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
    let symlink = engine.execute(overwrite, hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(symlink.conflicts?.first?.canReplace == false, "符号链接不可覆盖")
    let from = root.appendingPathComponent("from"); let to = root.appendingPathComponent("to")
    for directory in [from, to] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
    try Data("incoming".utf8).write(to: from.appendingPathComponent("same.txt"))
    try Data("old".utf8).write(to: to.appendingPathComponent("same.txt"))
    try Data("keep".utf8).write(to: to.appendingPathComponent("extra.txt"))
    overwrite = TransferJob(source: FileEndpoint(path: from.path), destination: FileEndpoint(path: to.path))
    let directoryConflict = engine.execute(overwrite, hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(directoryConflict.status == .awaitingConfirmation && directoryConflict.conflicts?.count == 2, "目录及内部冲突在写入前汇总")
    var merge = directoryConflict; merge.approvedConflicts = merge.conflicts
    let merged = engine.execute(merge, hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(merged.status == .completed && Data(contentsOf: to.appendingPathComponent("same.txt")) == Data("incoming".utf8), "确认目录合并并覆盖同名文件")
    try expect(try Data(contentsOf: to.appendingPathComponent("extra.txt")) == Data("keep".utf8), "目录合并保留额外文件")
    let incompatibleFile = root.appendingPathComponent("incompatible.txt")
    try Data("keep".utf8).write(to: incompatibleFile)
    let folderOverFile = engine.execute(TransferJob(source: FileEndpoint(path: from.path), destination: FileEndpoint(path: incompatibleFile.path)), hosts: [], cancellation: CancellationFlag()) { _ in }
    try expect(folderOverFile.status == .awaitingConfirmation && folderOverFile.conflicts?.count == 1, "目录覆盖文件时不遍历不兼容的目标子路径")
    for status in [TransferStatus.completed, .failed, .cancelled] { try expect(status.canClearRecord, "已结束状态允许清理记录") }
    for status in [TransferStatus.queued, .running, .paused, .awaitingConfirmation] { try expect(!status.canClearRecord, "未结束任务不得清理") }
}
