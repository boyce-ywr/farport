import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum TerminalClipboardChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let store = workspace.store
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        let terminal = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 400))
        pasteboard.clearContents(); pasteboard.setString("KEEP_EXISTING_CLIPBOARD", forType: .string)
        terminal.copy(terminal)
        guard pasteboard.string(forType: .string) == "KEEP_EXISTING_CLIPBOARD" else { throw WorkbenchError.message("无本地选区时复制清空了Mac剪贴板") }
        guard terminal.clipboard.failed, !terminal.clipboard.message.isEmpty else { throw WorkbenchError.message("没有选区时未提供反馈") }
        let window = NSWindow(contentRect: terminal.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = terminal; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let expected = "中文 😀 clipboard text"
        terminal.feed(text: "\u{1b}[2J\u{1b}[H" + expected)
        terminal.selectAll(); terminal.copy(terminal)
        guard pasteboard.string(forType: .string)?.contains(expected) == true, !terminal.clipboard.failed else { throw WorkbenchError.message("本地选中复制没有写入Mac剪贴板") }
        terminal.selectNone()
        let text = "COPY_FROM_MOUSE_SELECTION"
        terminal.feed(text: "\u{1b}[2J\u{1b}[H" + text + "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[>1s")
        var inputCount = 0; terminal.onInputActivity = { inputCount += 1 }
        let screen = terminal.getTerminal()
        let cell = terminal.cellSizeInPixels(source: screen)!
        let scale = window.backingScaleFactor
        let cellWidth = CGFloat(cell.width) / scale; let cellHeight = CGFloat(cell.height) / scale
        for (type, column, modifiers) in [(NSEvent.EventType.leftMouseDown, 0, NSEvent.ModifierFlags.shift), (.leftMouseDragged, 0, .shift), (.leftMouseDragged, text.count, .shift), (.leftMouseUp, text.count, [])] {
            let location = terminal.convert(NSPoint(x: CGFloat(column) * cellWidth + 1, y: terminal.bounds.height - cellHeight / 2), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw WorkbenchError.message("不能构造拖选事件") }
            if type == .leftMouseDown { terminal.mouseDown(with: event) }
            else if type == .leftMouseUp { terminal.mouseUp(with: event) }
            else { terminal.mouseDragged(with: event) }
            if type == .leftMouseDragged, column == text.count {
                terminal.dataReceived(slice: Array("\u{1b}[2;1HBACKGROUND_OUTPUT\u{1b}[1;1H".utf8)[...])
                guard terminal.getSelection() == text else { throw WorkbenchError.message("持续输出清除了正在Shift拖选的本地选区") }
            }
        }
        terminal.dataReceived(slice: Array("\u{1b}[2;1HMORE_OUTPUT\u{1b}[1;1H".utf8)[...])
        guard inputCount == 0, terminal.getSelection() == text, terminal.allowMouseReporting else { throw WorkbenchError.message("Shift拖选未绕过终端程序或改变鼠标配置：\(terminal.getSelection() ?? "nil")") }
        window.makeFirstResponder(terminal)
        let copyEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        guard terminal.performKeyEquivalent(with: copyEvent), pasteboard.string(forType: .string) == text, inputCount == 0 else { throw WorkbenchError.message("Cmd+C 未复制或误发给远端") }
        let menu = terminal.ordinaryContextMenu()
        guard let index = menu.items.firstIndex(where: { $0.title == L10n.text("复制") }) else { throw WorkbenchError.message("缺少复制菜单") }
        pasteboard.clearContents(); menu.performActionForItem(at: index)
        guard pasteboard.string(forType: .string) == text else { throw WorkbenchError.message("右键复制没有生效") }
        let editor = NSTextView(); editor.isRichText = false; editor.paste(nil)
        guard editor.string == text else { throw WorkbenchError.message("复制后在原生文本框粘贴不一致") }
        let remote = TerminalClipboardState()
        var prompts = 0
        remote.receive(Data("denied text".utf8), interactive: true) { prompts += 1; return false }
        remote.receive(Data("pending text".utf8), interactive: true) { prompts += 1; return true }
        guard prompts == 1, pasteboard.string(forType: .string) == text, remote.failed else { throw WorkbenchError.message("拒绝后再次复制缺少反馈或改写剪贴板") }
        remote.allowRemoteCopy()
        guard pasteboard.string(forType: .string) == "pending text", remote.pendingRemoteText == nil else { throw WorkbenchError.message("允许并补复制刚才内容失败") }
        remote.receive(Data("approved 中文".utf8), interactive: true) { prompts += 1; return false }
        guard prompts == 1, pasteboard.string(forType: .string) == "approved 中文" else { throw WorkbenchError.message("授权后每次弹窗或没有复制") }
        remote.receive(Data("background".utf8), interactive: false) { prompts += 1; return true }
        guard pasteboard.string(forType: .string) == "approved 中文", remote.pendingRemoteText == "background" else { throw WorkbenchError.message("后台终端覆盖了剪贴板") }
        remote.receive(Data([0xff]), interactive: true) { true }
        remote.receive(Data(repeating: 65, count: 1024 * 1024 + 1), interactive: true) { true }
        guard pasteboard.string(forType: .string) == "approved 中文", remote.failed else { throw WorkbenchError.message("无效或过大OSC52内容未拒绝") }
        remote.resetPermission()
        guard remote.remoteAllowed == nil, remote.pendingRemoteText == nil else { throw WorkbenchError.message("新连接继承了旧剪贴板授权") }
        try await checkCopyOrdering()
        let incoming = "OSC52 实际复制"
        terminal.clipboard.denyRemoteCopy()
        terminal.feed(text: "\u{1b}]52;c;\(Data(incoming.utf8).base64EncodedString())\u{7}")
        try await Task.sleep(for: .milliseconds(100))
        guard pasteboard.string(forType: .string) == "approved 中文", terminal.clipboard.pendingRemoteText == incoming else { throw WorkbenchError.message("真实OSC52未经过授权保护") }
        terminal.clipboard.allowRemoteCopy()
        guard pasteboard.string(forType: .string) == incoming else { throw WorkbenchError.message("OSC52补复制未写入Mac剪贴板") }
        guard terminal.terminalDelegate?.clipboardRead(source: terminal) == nil else { throw WorkbenchError.message("远端获得了Mac剪贴板读取权限") }
        terminal.selectNone()
        let wrapped = String(repeating: "中文😀 example-long-line ", count: 8)
        terminal.feed(text: "\u{1b}c" + wrapped)
        terminal.selectAll(); terminal.copy(terminal)
        guard pasteboard.string(forType: .string)?.trimmingCharacters(in: .newlines) == wrapped else { throw WorkbenchError.message("自动换行的中文/emoji复制加入了多余换行") }
        print("PASS · 无选区保护、Shift拖选绕过鼠标捕获、Cmd+C/右键复制与原生粘贴、OSC52授权/拒绝补复制、后台与无效内容保护")
        window.orderOut(nil)
        var hosts: [HostProfile?] = [nil]
        if let host = store.hosts.first(where: { $0.address == "127.0.0.1" && [22281, 22282].contains($0.port) }) { hosts.append(host) }
        for host in hosts {
            if let host { workspace.connect(host) } else { workspace.connectLocal() }
            guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("没有复制测试终端") }
            defer { workspace.close(session) }
            try await wait { session.connected && session.terminal.window != nil }
            session.terminal.clipboard.denyRemoteCopy()
            let value = "Farport OSC52 中文 " + UUID().uuidString
            let sequence = "\\033]52;c;\(Data(value.utf8).base64EncodedString())\\007"
            session.terminal.send(txt: "printf '\(sequence)'\n")
            try await wait { session.terminal.clipboard.pendingRemoteText == value }
            guard pasteboard.string(forType: .string) != value else { throw WorkbenchError.message("拒绝后真实PTY仍写剪贴板") }
            let recovery = session.terminal.ordinaryContextMenu()
            guard let recoverIndex = recovery.items.firstIndex(where: { $0.title == L10n.text("允许并复制刚才的内容") }) else { throw WorkbenchError.message("没有恢复复制菜单") }
            recovery.performActionForItem(at: recoverIndex)
            guard pasteboard.string(forType: .string) == value else { throw WorkbenchError.message("真实PTY复制不能通过菜单恢复") }
            let field = NSTextView(); field.isRichText = false; field.paste(nil)
            guard field.string == value else { throw WorkbenchError.message("真实PTY剪贴板粘贴到编辑器不一致") }
            let ready = "READY_" + UUID().uuidString
            let echoed = "PASTED_" + value
            session.terminal.send(txt: "stty -echo; printf '\\n%s\\n' \(RemotePath.quote(ready)); IFS= read -r line; printf '\\nPASTED_%s\\n' \"$line\"; stty echo\n")
            try await wait { hasLine(ready, session: session) }
            session.terminal.window?.makeFirstResponder(session.terminal)
            let pasteEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: session.terminal.window?.windowNumber ?? 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
            guard session.terminal.performKeyEquivalent(with: pasteEvent) else { throw WorkbenchError.message("Cmd+V未路由到当前终端") }
            try await Task.sleep(for: .milliseconds(200))
            guard !hasLine(echoed, session: session) else { throw WorkbenchError.message("文本粘贴自动发送了回车") }
            session.terminal.send(txt: "\r")
            try await wait { hasLine(echoed, session: session) }
            print("PASS · \(host == nil ? "本机" : "SSH") 实际OSC52请求→拒绝不覆盖→右键允许补复制→原生文本框粘贴")
            print("PASS · \(host == nil ? "本机" : "SSH") Cmd+V实际送达终端，内容一致且没有自动回车")
            workspace.close(session)
            let service = TmuxService(transport: store.transport, host: host)
            let name = "farport-copy-" + UUID().uuidString
            try service.create(name: name); defer { try? service.kill(session: name) }
            guard let tmux = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("测试tmux未创建") }
            workspace.attachTmux(host, session: tmux)
            guard let tmuxSession = workspace.selectedTerminal else { throw WorkbenchError.message("测试tmux未附着") }
            defer { workspace.close(tmuxSession) }
            try await wait { tmuxSession.connected && tmuxSession.terminal.window != nil }
            let selectedText = "TMUX_COPY_" + UUID().uuidString
            let shellCommand = "printf '\\n%s\\n' \(RemotePath.quote(selectedText))"
            _ = try service.execute("send-keys -t \(RemotePath.quote(name)) \(RemotePath.quote(shellCommand)) Enter").checked()
            try await wait {
                let screen = tmuxSession.terminal.getTerminal()
                return (0..<screen.rows).contains { screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).trimmingCharacters(in: .whitespaces) == selectedText }
            }
            tmuxSession.terminal.selectAll(); tmuxSession.terminal.copy(tmuxSession.terminal)
            guard pasteboard.string(forType: .string)?.contains(selectedText) == true else { throw WorkbenchError.message("tmux输出本地复制失败") }
            if host != nil, let content = tmuxSession.terminal.window?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output)
            }
            print("PASS · \(host == nil ? "本机" : "SSH") tmux输出经本地选区复制，不依赖tmux剪贴板设置")
        }
    }
    private static func checkCopyOrdering() async throws {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        let terminal = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        terminal.remoteSelectionContext = true
        terminal.clipboard.receive(Data("remote-before-cmd-c".utf8), interactive: true) { true }
        terminal.copy(terminal)
        guard !terminal.clipboard.failed, terminal.clipboard.message == L10n.text("已复制到 Mac 剪贴板"), pasteboard.string(forType: .string) == "remote-before-cmd-c" else { throw WorkbenchError.message("远端先完成复制时仍误报没有选区") }
        terminal.clipboard.resetPermission()
        terminal.copy(terminal)
        guard !terminal.clipboard.failed, terminal.clipboard.message.isEmpty else { throw WorkbenchError.message("等待远端复制前先闪失败提示") }
        try await Task.sleep(for: .milliseconds(100))
        terminal.clipboard.receive(Data("remote-after-cmd-c".utf8), interactive: true) { true }
        try await Task.sleep(for: .milliseconds(850))
        guard !terminal.clipboard.failed, terminal.clipboard.message == L10n.text("已复制到 Mac 剪贴板"), pasteboard.string(forType: .string) == "remote-after-cmd-c" else { throw WorkbenchError.message("延迟提示覆盖了实际复制成功") }
        pasteboard.clearContents(); pasteboard.setString("external", forType: .string)
        terminal.copy(terminal)
        try await Task.sleep(for: .milliseconds(900))
        guard terminal.clipboard.informational, !terminal.clipboard.failed, pasteboard.string(forType: .string) == "external" else { throw WorkbenchError.message("用旧复制记录覆盖剪贴板或误报失败") }
        terminal.clipboard.resetPermission()
        terminal.clipboard.receive(Data("denied".utf8), interactive: true) { false }
        terminal.copy(terminal)
        guard terminal.clipboard.failed, pasteboard.string(forType: .string) == "external" else { throw WorkbenchError.message("新反馈逻辑绕过了远端复制授权") }
        print("PASS · tmux先复制/后复制时序合并，延迟提示不覆盖成功，旧剪贴板与授权保护")
    }
    private static func hasLine(_ value: String, session: TerminalSession) -> Bool {
        let screen = session.terminal.getTerminal()
        return (0..<screen.rows).contains { screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).trimmingCharacters(in: .whitespaces) == value }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("终端复制检查超时") }; try await Task.sleep(for: .milliseconds(100)) }
    }
}
