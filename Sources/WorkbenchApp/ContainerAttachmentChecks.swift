import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum ContainerAttachmentChecks {
    static func run(workspace: Workspace, output: URL, interactive: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = environment["SWB_QA_DOCKER"], let identifier = environment["SWB_QA_CONTAINER_ID"] else { throw WorkbenchError.message("需要隔离Docker附件夹具") }
        let label = try ProcessRunner.run(executable: executable, arguments: ["inspect", "--format", "{{index .Config.Labels \"local.sshworkbench.docker-attachments\"}}", identifier]).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label == "true" else { throw WorkbenchError.message("拒绝向非测试容器发送附件") }
        let store = workspace.store
        let service = TmuxService(transport: store.transport, host: nil)
        let name = "farport-container-ui-" + UUID().uuidString
        try service.create(name: name)
        let original = store.automaticallyInsertAttachments
        let originalPreference = UserDefaults.standard.object(forKey: "automaticallyInsertAttachments")
        let clipboard = NSPasteboard.general
        let previous = clipboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            workspace.attachmentDraft?.dispose(); workspace.sessions.forEach { $0.close() }
            try? service.kill(session: name)
            store.automaticallyInsertAttachments = original
            if let originalPreference { UserDefaults.standard.set(originalPreference, forKey: "automaticallyInsertAttachments") } else { UserDefaults.standard.removeObject(forKey: "automaticallyInsertAttachments") }
            clipboard.clearContents()
            if let previous { clipboard.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        store.automaticallyInsertAttachments = interactive
        let receiver = "stty -echo; printf 'FARPORT_CONTAINER_READY'; for index in 1 2; do IFS= read -r line; printf '\\nFARPORT_RECEIVED_%s\\n%s\\n' \"$index\" \"$line\"; done; sleep 60"
        let command = [executable, "exec", "-it", "--user", "tester", identifier, "sh", "-c", receiver].map(RemotePath.quote).joined(separator: " ")
        _ = try service.execute("respawn-pane -k -t \(RemotePath.quote(name)) \(RemotePath.quote(command))").checked()
        guard let tmux = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("没有容器测试会话") }
        workspace.attachTmux(nil, session: tmux)
        guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("没有附件终端") }
        try await wait { session.connected && session.terminal.window != nil }
        if interactive {
            session.terminal.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait { NSApp.isActive && NSApp.keyWindow === session.terminal.window }
        }
        try await wait { (try? service.execute("capture-pane -p -t \(RemotePath.quote(name))").checked().text.contains("FARPORT_CONTAINER_READY")) == true }
        let file = store.paths.root.appendingPathComponent("container 图片.png")
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bytes = image.representation(using: .png, properties: [:]) else { throw WorkbenchError.message("无法创建图片夹具") }
        try bytes.write(to: file)
        for iteration in 1...2 {
            guard let window = session.terminal.window else { throw WorkbenchError.message("没有附件目标窗口") }
            if interactive {
                clipboard.clearContents()
                if iteration == 1 { clipboard.setData(bytes, forType: .png) } else { clipboard.writeObjects([file as NSURL]) }
                window.makeFirstResponder(session.terminal)
                guard
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9),
                  NSApp.mainMenu?.performKeyEquivalent(with: event) == true || window.performKeyEquivalent(with: event) else { throw WorkbenchError.message("Cmd+V未派发") }
            } else { workspace.requestAttachments(session: session, payload: TerminalAttachmentPayload(files: [file], temporaryDirectory: nil)) }
            guard let draft = workspace.attachmentDraft else { throw WorkbenchError.message("没有容器附件草稿") }
            if iteration == 1 {
                try await wait { draft.containerSelection != nil || draft.failure != nil }
                guard draft.containerSelection?.detectedContainerID == identifier, draft.result == nil, draft.failure == nil else { throw WorkbenchError.message(draft.failure ?? "未确认前发生上传或未识别目标容器") }
                if interactive { try await wait { window.attachedSheet != nil } }
                if let content = window.attachedSheet?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output)
                }
                if interactive {
                    guard let sheet = window.attachedSheet,
                          let confirm = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw WorkbenchError.message("没有容器确认弹窗") }
                    NSApp.postEvent(confirm, atStart: false)
                } else { await draft.chooseContainer(identifier) }
            }
            if !interactive {
                try await wait { (!draft.busy && draft.result != nil) || draft.failure != nil }
                guard draft.failure == nil, !draft.inserted else { throw WorkbenchError.message(draft.failure ?? "手动策略未保持") }
                await draft.insert()
            }
            try await wait { draft.inserted || draft.failure != nil }
            guard draft.inserted, let result = draft.result, draft.dockerBinding?.container.id == identifier, draft.containerSelection == nil else { throw WorkbenchError.message(draft.failure ?? "未插入容器附件") }
            let content = try ProcessRunner.run(executable: executable, arguments: ["exec", "--user", "tester", identifier, "cat", result.paths[0]]).checked().output
            guard content == (try Data(contentsOf: draft.payload.files[0])) else { throw WorkbenchError.message("容器用户读到内容不一致") }
            let marker = "FARPORT_RECEIVED_\(iteration)"
            guard try !service.execute("capture-pane -p -J -t \(RemotePath.quote(name))").checked().text.contains(marker) else { throw WorkbenchError.message("自动插入不应回车") }
            _ = try service.execute("send-keys -t \(RemotePath.quote(name)) Enter").checked()
            let reference = try AttachmentReference.text(paths: result.paths).trimmingCharacters(in: .whitespacesAndNewlines)
            try await wait {
                guard let text = try? service.execute("capture-pane -p -J -t \(RemotePath.quote(name))").checked().text else { return false }
                return text.contains(marker) && text.components(separatedBy: reference).count == 2
            }
            await draft.deleteUploaded(); draft.dispose(); workspace.attachmentDraft = nil
        }
        _ = try service.execute("respawn-pane -k -t \(RemotePath.quote(name)) \(RemotePath.quote(command))").checked()
        try await wait { (try? service.execute("capture-pane -p -t \(RemotePath.quote(name))").checked().text.contains("FARPORT_CONTAINER_READY")) == true }
        workspace.requestAttachments(session: session, payload: TerminalAttachmentPayload(files: [file], temporaryDirectory: nil))
        guard let changed = workspace.attachmentDraft else { throw WorkbenchError.message("没有重连后的容器草稿") }
        try await wait { changed.containerSelection != nil || changed.failure != nil }
        guard changed.containerSelection != nil, changed.result == nil, session.dockerAttachmentBinding == nil else { throw WorkbenchError.message("新的Docker进程复用了旧绑定") }
        changed.cancel()
        guard changed.result == nil, !changed.inserted, !changed.showContainerPicker else { throw WorkbenchError.message("取消选择仍产生了容器发送") }
        try await Task.sleep(for: .milliseconds(300))
        try await wait { session.terminal.window?.attachedSheet == nil }
        changed.dispose(); workspace.attachmentDraft = nil
        print(interactive ? "PASS · 本机tmux Docker真实Cmd+V、首次确认界面、后续绑定复用、非root读回、容器路径只插入一次且不自动回车"
              : "PASS · Docker附件草稿准备/确认/绑定复用/手动插入/清理完整链，非root容器只收到一次路径；不代表界面点击或自动焦点验收")
        fflush(stdout)
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(35)
        while !condition() {
            guard Date() < deadline else { throw WorkbenchError.message("容器附件界面回归超时：\(line)，active=\(NSApp.isActive)") }
            try await Task.sleep(for: .milliseconds(70))
        }
    }
}
