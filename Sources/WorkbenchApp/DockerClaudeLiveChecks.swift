import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum DockerClaudeLiveChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["SWB_QA_LIVE_TMUX_NAME"], name.hasPrefix("farport-docker-claude-check-"),
              let containerID = environment["SWB_QA_CONTAINER_ID"], containerID.count == 64 else { throw WorkbenchError.message("需要明确的独立docker-claude测试会话") }
        let service = TmuxService(transport: workspace.store.transport, host: nil)
        guard let tmux = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("找不到指定的独立docker-claude会话") }
        let file = workspace.store.paths.root.appendingPathComponent("project/farport-image-test.png")
        let image = try Data(contentsOf: file)
        let clipboard = NSPasteboard.general
        let previous = clipboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        let preference = UserDefaults.standard.object(forKey: "automaticallyInsertAttachments")
        let automatic = workspace.store.automaticallyInsertAttachments
        defer {
            workspace.attachmentDraft?.dispose(); workspace.sessions.forEach { $0.close() }
            workspace.store.automaticallyInsertAttachments = automatic
            if let preference { UserDefaults.standard.set(preference, forKey: "automaticallyInsertAttachments") } else { UserDefaults.standard.removeObject(forKey: "automaticallyInsertAttachments") }
            clipboard.clearContents()
            if let previous { clipboard.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        workspace.store.automaticallyInsertAttachments = true
        workspace.attachTmux(nil, session: tmux)
        guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("没有实际Claude终端") }
        try await wait { session.connected && session.terminal.window != nil }
        guard let window = session.terminal.window else { throw WorkbenchError.message("实际Claude终端没有窗口") }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait { NSApp.isActive && window.isKeyWindow }
        window.makeFirstResponder(session.terminal)
        clipboard.clearContents(); clipboard.setData(image, forType: .png)
        guard let paste = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9),
              NSApp.mainMenu?.performKeyEquivalent(with: paste) == true || window.performKeyEquivalent(with: paste) else { throw WorkbenchError.message("真实Cmd+V未派发") }
        guard let draft = workspace.attachmentDraft else { throw WorkbenchError.message("未创建实际Claude附件") }
        try await wait { draft.containerSelection != nil || draft.failure != nil }
        guard draft.containerSelection?.detectedContainerID == containerID, draft.failure == nil, draft.result == nil else { throw WorkbenchError.message(draft.failure ?? "实际目标与预期docker-claude不符") }
        try await wait { window.attachedSheet != nil }
        guard let sheet = window.attachedSheet,
              let confirm = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw WorkbenchError.message("没有容器确认弹窗") }
        NSApp.postEvent(confirm, atStart: false)
        try await wait { draft.inserted || draft.failure != nil }
        guard draft.inserted, draft.dockerBinding?.container.id == containerID, let result = draft.result else { throw WorkbenchError.message(draft.failure ?? "实际Claude附件没有插入") }
        try result.paths.joined(separator: "\n").write(to: workspace.store.paths.root.appendingPathComponent("inserted-container-path.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        print("PASS · 实际docker-claude独立会话：DOCKER_HOST Unix socket、真实Cmd+V、容器确认、文件校验及路径插入；未发送回车，不代表模型已读取")
        fflush(stdout)
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(45)
        while !condition() {
            guard Date() < deadline else { throw WorkbenchError.message("实际docker-claude验收超时：\(line)，active=\(NSApp.isActive)") }
            try await Task.sleep(for: .milliseconds(80))
        }
    }
}
