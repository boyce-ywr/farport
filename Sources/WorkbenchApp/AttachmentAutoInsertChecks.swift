import AppKit
import WorkbenchCore
import OpenSSHBackend
import Combine

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
            let transport = store.transport
            let receivedPath = host == nil ? store.paths.root.appendingPathComponent("attachment-input-\(UUID().uuidString)").path : "/tmp/farport-attachment-input-\(UUID().uuidString)"
            defer { let client = try? transport.files(host); try? client?.removeRecursively(receivedPath); client?.close() }
            let readySuffix = UUID().uuidString
            session.terminal.send(txt: "stty -echo -icanon; : > \(RemotePath.quote(receivedPath)); printf '\\n%s%s\\n' 'FARPORT_ATTACHMENT_' '\(readySuffix)'; cat >> \(RemotePath.quote(receivedPath))\n")
            try await wait {
                let terminal = session.terminal.getTerminal()
                return (0..<terminal.rows).contains { terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).trimmingCharacters(in: .whitespaces) == "FARPORT_ATTACHMENT_" + readySuffix }
            }
            print("PASS · \(host == nil ? "本机" : "隔离 SSH") 附件接收器已实际启动，开始发送剪贴板内容")
            clipboard.clearContents(); clipboard.setString("FARPORT_PASTE_TEXT", forType: .string)
            let before = session.inputGeneration
            try paste(session.terminal)
            guard workspace.attachmentDraft == nil, session.inputGeneration > before else { throw WorkbenchError.message("纯文本粘贴没有直接发送") }
            for kind in ["image", "file", "drop", "same-tab", "focus-blip", "typing", "manual", "switch-back", "switch"] {
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
                var focusSubscription: AnyCancellable?
                var sawTemporaryBlock = false
                var temporaryWindow: NSWindow?
                if kind == "focus-blip", let originalWindow = session.terminal.window {
                    focusSubscription = draft.$result.sink { uploaded in
                        guard uploaded != nil, !sawTemporaryBlock else { return }
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
                        temporaryWindow = window; window.makeKeyAndOrderFront(nil)
                        sawTemporaryBlock = !workspace.canAutomaticallyInsert(draft)
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
                            window.orderOut(nil); originalWindow.makeKeyAndOrderFront(nil); originalWindow.makeFirstResponder(session.terminal)
                        }
                    }
                }
                session.terminal.feed(text: "\u{1b}[6n\u{1b}[c\u{1b}[>c")
                workspace.selectTerminal(session)
                if kind == "same-tab" { workspace.chooseTab(session) }
                if kind == "typing" { session.terminal.send(txt: "keep typing") }
                if kind == "switch-back" { workspace.page = .transfers; workspace.page = .terminal }
                if kind == "switch" { workspace.connectLocal(split: true) }
                try await wait { draft.result != nil || draft.failure != nil }
                if ["typing", "manual", "switch"].contains(kind) {
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
                    if kind == "focus-blip", !sawTemporaryBlock { throw WorkbenchError.message("没有覆盖上传完成时的短暂失焦") }
                    await draft.insert()
                    let reference = try AttachmentReference.text(paths: result.paths)
                    let deadline = Date().addingTimeInterval(5)
                    while true {
                        let received = try await Task.detached { let client = try transport.files(host); defer { client.close() }; return String(decoding: try client.preview(receivedPath), as: UTF8.self) }.value
                        let copies = received.components(separatedBy: reference).count - 1
                        guard copies <= 1, !received.contains("\n"), !received.contains("\r") else { throw WorkbenchError.message("附件重复插入或自动发送了回车") }
                        if copies == 1 { break }
                        guard Date() < deadline else { throw WorkbenchError.message("标记已插入但实际终端没有收到路径") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                focusSubscription?.cancel(); temporaryWindow?.orderOut(nil)
                print("PASS · \(host == nil ? "本机" : "隔离 SSH") 附件案例 \(kind)")
                await draft.deleteUploaded(); draft.dispose(); workspace.attachmentDraft = nil
                if kind == "switch", let other = workspace.selectedTerminal, other !== session { workspace.close(other); workspace.selectTerminal(session) }
            }
            workspace.close(session)
            print("PASS · \(host == nil ? "本机" : "隔离 SSH") Cmd+V 图片/文件实际送达一次且不回车、同标签/短暂失焦/页面往返恢复、手动策略/输入/停留他处保护")
        }
        for host in targets {
            let service = TmuxService(transport: store.transport, host: host)
            let name = "farport-autopaste-" + UUID().uuidString
            try service.create(name: name)
            defer { try? service.kill(session: name) }
            let command = "stty -echo; printf 'FARPORT_WAITING'; IFS= read -r line; printf '\\nFARPORT_ATTACHMENT_RECEIVED\\n%s\\n' \"$line\"; sleep 5"
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
            guard draft.inserted, draft.target != nil, let uploaded = draft.result else { throw WorkbenchError.message(draft.failure ?? "tmux 附件未自动插入") }
            try await Task.sleep(for: .milliseconds(250))
            guard try !service.execute("capture-pane -p -t \(RemotePath.quote(name))").checked().text.contains("FARPORT_ATTACHMENT_RECEIVED") else { throw WorkbenchError.message("tmux 自动插入错误发送了回车") }
            _ = try service.execute("send-keys -t \(RemotePath.quote(name)) Enter").checked()
            let reference = try AttachmentReference.text(paths: uploaded.paths).trimmingCharacters(in: .whitespacesAndNewlines)
            try await wait {
                guard let received = try? service.execute("capture-pane -p -J -t \(RemotePath.quote(name))").checked().text else { return false }
                return received.contains("FARPORT_ATTACHMENT_RECEIVED") && received.components(separatedBy: reference).count == 2
            }
            await draft.deleteUploaded(); draft.dispose(); workspace.attachmentDraft = nil
            workspace.close(session)
            print("PASS · \(host == nil ? "本机" : "隔离 SSH") tmux Cmd+V 原窗格实际收到一次路径，只有测试主动回车才提交")
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
