import AppKit
import Foundation
import WorkbenchCore
import OpenSSHBackend

final class AttachmentDragFixture: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, window: NSWindow?) { draggingPasteboard = pasteboard; draggingDestinationWindow = window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
enum AttachmentChecks {
    static func run(workspace: Workspace) async throws {
        guard let host = workspace.store.hosts.first, host.address == "127.0.0.1", host.port == 22281 else { throw WorkbenchError.message("附件界面测试仅允许隔离主机") }
        let transport = workspace.store.transport
        let reportURL = workspace.store.paths.root.deletingLastPathComponent().appendingPathComponent("attachment-report.json")
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as! [String: Any]
        let sourceImage = URL(fileURLWithPath: report["localImage"] as! String)
        let imageData = try Data(contentsOf: sourceImage)
        workspace.connect(host)
        guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("测试终端未创建") }
        try await wait("SSH 未连接") { session.connected }
        session.terminal.send(txt: "stty -echo; python3 -c \"import sys,time; sys.stdin.readline(); time.sleep(20)\"\n")
        try await Task.sleep(for: .milliseconds(400))

        let clipboard = NSPasteboard(name: .init("farport-check-" + UUID().uuidString))
        defer { clipboard.releaseGlobally() }
        clipboard.setData(imageData, forType: .png)
        guard session.terminal.receiveAttachments(from: clipboard), let draft = workspace.attachmentDraft else { throw WorkbenchError.message("图片粘贴未进入附件流程") }
        try await wait("图片上传插入未完成", timeout: 40) { draft.inserted || draft.failure != nil }
        guard draft.inserted, let result = draft.result else { throw WorkbenchError.message(draft.failure ?? "未插入附件") }
        guard NSApp.windows.allSatisfy({ $0.sheets.isEmpty }), result.paths[0].hasPrefix("/tmp/") else { throw WorkbenchError.message("附件仍要求弹窗或没有使用远端临时目录") }
        let client = try transport.sftp(host); defer { client.close() }
        let remoteImage = try client.preview(result.paths[0], limit: 2 * 1024 * 1024)
        guard NSImage(data: remoteImage) != nil, !result.paths[0].hasPrefix("/Users/") else {
            throw WorkbenchError.message("粘贴的图片未实际上传到远端")
        }
        draft.dispose(); workspace.attachmentDraft = nil
        try await Task.sleep(for: .milliseconds(350))
        print("PASS · 图片粘贴免弹窗 → 对端私有临时目录 → 回读校验 → 原终端路径（不回车）")

        clipboard.clearContents(); clipboard.writeObjects([sourceImage as NSURL])
        let drop = AttachmentDragFixture(pasteboard: clipboard, window: session.terminal.window)
        guard session.terminal.draggingEntered(drop) == .copy, session.terminal.performDragOperation(drop), let dropped = workspace.attachmentDraft else {
            throw WorkbenchError.message("拖拽文件没有进入同一附件流程")
        }
        workspace.connectLocal(split: true)
        try await wait("拖拽上传未完成", timeout: 40) { dropped.result != nil || dropped.failure != nil }
        guard dropped.result != nil, !dropped.inserted else { throw WorkbenchError.message("切换终端后错误地自动插入了附件") }
        guard workspace.selectedTerminal?.isLocal == true else { throw WorkbenchError.message("上传回调篡改了焦点") }
        dropped.dispose(); workspace.attachmentDraft = nil
        print("PASS · 原生拖拽回调 → 上传锁定原终端；切换本机标签后不误发")

        workspace.selectTerminal(session)
        clipboard.clearContents(); clipboard.writeObjects([sourceImage.deletingLastPathComponent().appendingPathComponent("missing.png") as NSURL])
        _ = session.terminal.receiveAttachments(from: clipboard)
        guard let invalid = workspace.attachmentDraft else { throw WorkbenchError.message("失败测试未创建") }
        try await wait("缺失文件未失败", timeout: 30) { invalid.failure != nil }
        guard invalid.result == nil, !invalid.inserted else { throw WorkbenchError.message("失败仍插入路径") }
        invalid.dispose(); workspace.attachmentDraft = nil
        print("PASS · 上传失败不向终端插入路径")

        let service = TmuxService(transport: transport, host: nil)
        let name = "farport-ui-" + String(UUID().uuidString.prefix(8))
        try service.create(name: name)
        guard let tmux = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("本机 tmux 创建失败") }
        defer { try? service.kill(session: tmux.id) }
        workspace.attachTmux(nil, session: tmux)
        guard let localTmux = workspace.selectedTerminal else { throw WorkbenchError.message("本机 tmux 终端未创建") }
        try await wait("本机 tmux 无法附着") { localTmux.connected }
        guard localTmux.isLocal, localTmux.tmuxID == tmux.id else { throw WorkbenchError.message("本机 tmux 被当成 SSH") }
        workspace.close(localTmux)
        guard try service.sessions().contains(where: { $0.id == tmux.id }) else { throw WorkbenchError.message("关闭本机 tmux 标签误杀会话") }
        print("PASS · 本机 tmux 原生管理/附着，关闭标签会话继续")
        workspace.sessions.forEach { $0.close() }
        workspace.connectLocal()
        try await wait("本机终端未就绪") { workspace.selectedTerminal?.connected == true }
        workspace.selectedTerminal?.terminal.send(txt: "printf '\\n附件上传与本机 tmux 验证通过\\n'\n")
    }
    private static func wait(_ failure: String, timeout: TimeInterval = 20, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message(failure) }; try await Task.sleep(for: .milliseconds(100)) }
    }
}
