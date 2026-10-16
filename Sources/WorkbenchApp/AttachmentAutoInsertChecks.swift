import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum AttachmentAutoInsertChecks {
    static func run(workspace: Workspace) async throws {
        let probe = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var activity = 0
        probe.onInputActivity = { activity += 1 }
        probe.feed(text: "\u{1b}[6n\u{1b}[c\u{1b}[>c")
        guard activity == 0 else { throw WorkbenchError.message("终端查询自动回包被计为用户输入：\(activity) 次，会拦截附件自动插入") }
        probe.send(txt: "user input")
        guard activity > 0 else { throw WorkbenchError.message("真实输入未触发附件保护") }
        print("PASS · 终端自动回包不改变输入版本，真实输入仍触发保护")
        let store = workspace.store
        let original = store.automaticallyInsertAttachments
        let defaultValue = UserDefaults.standard.object(forKey: "automaticallyInsertAttachments")
        let clipboard = NSPasteboard.general
        let previous = clipboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            store.automaticallyInsertAttachments = original
            if let defaultValue { UserDefaults.standard.set(defaultValue, forKey: "automaticallyInsertAttachments") } else { UserDefaults.standard.removeObject(forKey: "automaticallyInsertAttachments") }
            clipboard.clearContents()
            if let previous { clipboard.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
            workspace.attachmentDraft?.dispose(); workspace.sessions.forEach { $0.close() }
        }
        store.automaticallyInsertAttachments = true
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = image.representation(using: .png, properties: [:])!
        let file = store.paths.root.appendingPathComponent("复制的图片.png")
        try png.write(to: file)
        var targets: [HostProfile?] = [nil]
        if let host = store.hosts.first(where: { $0.address == "127.0.0.1" && $0.port == 22281 }) { targets.append(host) }
        for host in targets {
            if let host { workspace.connect(host) } else { workspace.connectLocal() }
            guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("没有附件测试终端") }
            try await wait { session.connected && session.terminal.window != nil }
            session.terminal.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait { NSApp.isActive && NSApp.keyWindow === session.terminal.window }
            session.terminal.send(txt: "stty -echo; cat > /dev/null\n")
            try await Task.sleep(for: .milliseconds(300))
            clipboard.clearContents(); clipboard.setString("FARPORT_PASTE_TEXT", forType: .string)
            let before = session.inputGeneration
            try paste(session.terminal)
            guard workspace.attachmentDraft == nil, session.inputGeneration > before else { throw WorkbenchError.message("纯文本粘贴没有直接发送") }
            for kind in ["image", "file", "drop", "typing", "manual", "switch-back", "switch"] {
                store.automaticallyInsertAttachments = kind != "manual"
                clipboard.clearContents()
                if kind == "image" { clipboard.setData(png, forType: .png) }
                else { clipboard.writeObjects([file as NSURL]) }
                if kind == "drop" {
                    guard session.terminal.performDragOperation(AttachmentDragFixture(pasteboard: clipboard, window: session.terminal.window)) else { throw WorkbenchError.message("Finder 文件拖入没有进入附件流程") }
                } else if kind == "file" {
                    let menu = session.terminal.ordinaryContextMenu()
                    guard let index = menu.items.firstIndex(where: { $0.title == L10n.text("粘贴") }), menu.items[index].isEnabled else { throw WorkbenchError.message("右键菜单没有可用的粘贴项") }
                    menu.performActionForItem(at: index)
                } else { try paste(session.terminal) }
                guard let draft = workspace.attachmentDraft else { throw WorkbenchError.message("剪贴板附件没有进入上传流程") }
                session.terminal.feed(text: "\u{1b}[6n\u{1b}[c\u{1b}[>c")
                workspace.selectTerminal(session)
                if kind == "typing" { session.terminal.send(txt: "keep typing") }
                if kind == "switch-back" { workspace.page = .transfers; workspace.page = .terminal }
                if kind == "switch" { workspace.connectLocal(split: true) }
                try await wait { draft.result != nil || draft.failure != nil }
                if ["typing", "manual", "switch", "switch-back"].contains(kind) {
                    try await Task.sleep(for: .milliseconds(200))
                    guard !draft.inserted, draft.result != nil else { throw WorkbenchError.message("手动策略或继续输入保护失效") }
                } else {
                    try await wait { draft.inserted || draft.failure != nil }
                    guard draft.inserted, draft.failure == nil, let result = draft.result else { throw WorkbenchError.message(draft.failure ?? "复制粘贴上传后仍需要手动插入") }
                    let transport = store.transport
                    let saved = try await Task.detached { let client = try transport.files(host); defer { client.close() }; return try client.preview(result.paths[0]) }.value
                    let decoded = NSBitmapImageRep(data: saved)
                    let verified = kind == "image" ? decoded?.pixelsWide == 32 && decoded?.pixelsHigh == 32 : saved == png
                    guard verified else { throw WorkbenchError.message("附件目标回读不一致") }
                }
                await draft.deleteUploaded(); draft.dispose(); workspace.attachmentDraft = nil
                if kind == "switch", let other = workspace.selectedTerminal, other !== session { workspace.close(other); workspace.selectTerminal(session) }
            }
            workspace.close(session)
            print("PASS · \(host == nil ? "本机" : "隔离 SSH") Cmd+V 文本/图片、右键粘贴 Finder 文件、自动回包期间自动插入、手动策略/输入/目标切换保护")
        }
        for host in targets {
            let service = TmuxService(transport: store.transport, host: host)
            let name = "farport-autopaste-" + UUID().uuidString
            try service.create(name: name)
            defer { try? service.kill(session: name) }
            let command = "stty -echo; printf 'FARPORT_WAITING'; IFS= read -r line; printf '\\nFARPORT_UNEXPECTED_ENTER\\n'"
            _ = try service.execute("respawn-pane -k -t \(RemotePath.quote(name)) \(RemotePath.quote(command))").checked()
            guard let tmux = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("tmux 附件测试会话未创建") }
            workspace.attachTmux(host, session: tmux)
            guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("tmux 附件目标未附着") }
            try await wait { session.connected && session.terminal.window != nil }
            session.terminal.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait { NSApp.isActive && NSApp.keyWindow === session.terminal.window }
            try await wait { (try? service.execute("capture-pane -p -t \(RemotePath.quote(name))").checked().text.contains("FARPORT_WAITING")) == true }
            store.automaticallyInsertAttachments = true
            clipboard.clearContents(); clipboard.writeObjects([file as NSURL])
            try paste(session.terminal)
            guard let draft = workspace.attachmentDraft else { throw WorkbenchError.message("tmux 粘贴没有创建附件") }
            session.terminal.feed(text: "\u{1b}[6n\u{1b}[c")
            try await wait { draft.inserted || draft.failure != nil }
            guard draft.inserted, draft.target != nil else { throw WorkbenchError.message(draft.failure ?? "tmux 附件未自动插入") }
            try await Task.sleep(for: .milliseconds(250))
            guard try !service.execute("capture-pane -p -t \(RemotePath.quote(name))").checked().text.contains("FARPORT_UNEXPECTED_ENTER") else { throw WorkbenchError.message("tmux 自动插入错误发送了回车") }
            await draft.deleteUploaded(); draft.dispose(); workspace.attachmentDraft = nil
            workspace.close(session)
            print("PASS · \(host == nil ? "本机" : "隔离 SSH") tmux Cmd+V 自动插入原窗格，未自动回车")
        }
    }
    private static func paste(_ terminal: SafeTerminalView) throws {
        guard let window = terminal.window else { throw WorkbenchError.message("粘贴目标没有窗口") }
        window.makeFirstResponder(terminal)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9),
              NSApp.mainMenu?.performKeyEquivalent(with: event) == true || window.performKeyEquivalent(with: event) else { throw WorkbenchError.message("Cmd+V 没有派发到终端") }
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("附件自动插入回归超时：\(line)，active=\(NSApp.isActive)") }; try await Task.sleep(for: .milliseconds(60)) }
    }
}
