import Foundation
import WorkbenchCore

@MainActor
enum TransferWorkflowChecks {
    static func run(workspace: Workspace) async throws {
        let store = workspace.store
        let root = store.paths.root.appendingPathComponent("transfer-check")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt"); let target = root.appendingPathComponent("target.txt")
        try Data("new".utf8).write(to: source); try Data("original".utf8).write(to: target)
        let job = TransferJob(source: FileEndpoint(path: source.path), destination: FileEndpoint(path: target.path))
        store.queue(job)
        try await wait { store.pendingConflict?.id == job.id }
        guard try Data(contentsOf: target) == Data("original".utf8) else { throw WorkbenchError.message("确认前发生覆盖") }
        store.approveOverwrite(store.pendingConflict!)
        try await wait { store.transfers.first(where: { $0.id == job.id })?.status == .completed }
        guard try Data(contentsOf: target) == Data("new".utf8) else { throw WorkbenchError.message("批准后未正确覆盖") }
        try await Task.sleep(for: .milliseconds(200))
        var cancelled = job; cancelled.id = UUID(); cancelled.status = .cancelled
        var failed = job; failed.id = UUID(); failed.status = .failed
        var paused = job; paused.id = UUID(); paused.status = .paused
        store.transfers += [cancelled, failed, paused]
        let partial = root.appendingPathComponent("target.txt.swb-\(cancelled.id.uuidString).part")
        try Data("partial".utf8).write(to: partial)
        store.clearTransferRecords(abnormalOnly: true)
        guard store.transfers.map(\.id).contains(job.id), store.transfers.map(\.id).contains(paused.id),
              !store.transfers.contains(where: { $0.id == cancelled.id || $0.id == failed.id }), FileManager.default.fileExists(atPath: partial.path) else { throw WorkbenchError.message("异常记录清理误删文件或暂停任务") }
        store.clearTransferRecords()
        guard store.transfers.contains(where: { $0.id == paused.id }), !store.transfers.contains(where: { $0.id == job.id }) else { throw WorkbenchError.message("清理已结束记录错误") }
        store.cancel(paused); store.clearTransferRecords()
        try Data("existing".utf8).write(to: target)
        store.queue(TransferJob(source: FileEndpoint(path: source.path), destination: FileEndpoint(path: target.path)))
        try await wait { store.pendingConflict != nil }
        workspace.page = .transfers
        print("PASS · 队列冲突等待、批准恢复、仅清除已结束记录并保留断点和暂停任务")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition() { guard Date() < end else { throw WorkbenchError.message("传输队列验收超时") }; try await Task.sleep(for: .milliseconds(80)) }
    }
}
