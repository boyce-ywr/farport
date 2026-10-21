import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum TerminalPasteChecks {
    static func run(store: AppStore, output: URL) async throws {
        let root = output.deletingLastPathComponent()
        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        let oldConfirmation = store.confirmMultilinePaste
        let preference = UserDefaults.standard.object(forKey: "confirmMultilinePaste")
        defer {
            store.confirmMultilinePaste = oldConfirmation
            if let preference { UserDefaults.standard.set(preference, forKey: "confirmMultilinePaste") } else { UserDefaults.standard.removeObject(forKey: "confirmMultilinePaste") }
            board.clearContents()
            if let previous { board.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        let terminal = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 780, height: 480))
        terminal.clipboard.writePolicy = { .allow }
        terminal.clipboard.readAllowed = { true }
        terminal.confirmsMultilinePaste = { store.confirmMultilinePaste }
        let window = NSWindow(contentRect: terminal.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = terminal
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(terminal)
        defer { terminal.process.terminate(); window.orderOut(nil) }
        let socket = "farport-paste-" + UUID().uuidString
        let executable = try TmuxService.localExecutable()
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
        environment["TERM"] = "xterm-256color"
        func tmux(_ arguments: [String]) throws -> String {
            try ProcessRunner.run(executable: executable, arguments: ["-L", socket] + arguments, environment: environment, timeout: 5).checked().text.trimmingCharacters(in: .newlines)
        }
        defer { _ = try? tmux(["kill-server"]) }
        _ = try tmux(["-f", "/dev/null", "new-session", "-d", "-s", "paste", "/bin/sh"])
        _ = try tmux(["set-option", "-g", "default-shell", "/bin/sh"])
        _ = try tmux(["set-option", "-g", "set-clipboard", "on"])
        _ = try tmux(["set-option", "-g", "mouse", "on"])
        terminal.startProcess(executable: executable, args: ["-L", socket, "attach-session", "-t", "paste"], environment: environment.map { "\($0.key)=\($0.value)" })
        try await wait { terminal.process.running && terminal.getTerminal().getLine(row: 0) != nil }
        try await Task.sleep(for: .milliseconds(500))
        let original = try tmux(["display-message", "-p", "-t", "paste", "#{pane_id}"])
        terminal.send(txt: "\u{2}c")
        try await wait { (try? tmux(["display-message", "-p", "-t", "paste", "#{pane_id}"])) != original }
        let receiver = root.appendingPathComponent("receive.py")
        let received = root.appendingPathComponent("received.bin")
        let ready = root.appendingPathComponent("ready")
        try """
        import os, pathlib, select, sys, termios, tty
        before = termios.tcgetattr(0)
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?2004h')
            pathlib.Path(sys.argv[2]).touch()
            with open(sys.argv[1], 'wb', buffering=0) as output:
                while select.select([0], [], [], 15)[0]:
                    output.write(os.read(0, 65536))
        finally:
            termios.tcsetattr(0, termios.TCSANOW, before)
        """.write(to: receiver, atomically: true, encoding: .utf8)
        terminal.send(txt: "python3 \(RemotePath.quote(receiver.path)) \(RemotePath.quote(received.path)) \(RemotePath.quote(ready.path))\n")
        try await wait { FileManager.default.fileExists(atPath: ready.path) && terminal.getTerminal().bracketedPasteMode }
        guard preference != nil || oldConfirmation else { throw WorkbenchError.message("多行粘贴确认未默认开启") }
        let cases: [(name: String, text: String, ask: Bool, cancel: Bool, change: Bool, bracketed: Bool)] = [
            ("确认", "PASTE 中文😀\nsecond line", true, false, false, true),
            ("确认期间剪贴板变化", "ORIGINAL 中文😀\nsecond line", true, false, true, true),
            ("取消", "CANCEL\nsecond line", true, true, false, true),
            ("关闭确认", "DIRECT\nsecond line", false, false, false, true),
            ("单行", "single 中文😀", true, false, false, true),
            ("CRLF", "first\r\nsecond\rthird", true, false, false, true),
            ("非括号粘贴与增强键盘", "RAW\nsecond line", true, false, false, false)
        ]
        for scenario in cases {
            store.confirmMultilinePaste = scenario.ask
            guard UserDefaults.standard.object(forKey: "confirmMultilinePaste") as? Bool == scenario.ask else { throw WorkbenchError.message("多行确认设置未保存") }
            if !scenario.bracketed { terminal.feed(text: "\u{1b}[?2004l\u{1b}[>31u") }
            board.clearContents(); board.setString(scenario.text, forType: .string)
            var expectedClipboard = scenario.text
            var expectedChange = board.changeCount
            let beforeCount = (try? Data(contentsOf: received).count) ?? 0
            var confirmed = false
            let deadline = Date().addingTimeInterval(5)
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if Date() > deadline { NSApp.abortModal(); return }
                    guard !confirmed, let content = NSApp.modalWindow?.contentView,
                          let button = buttons(in: content).first(where: { $0.title == L10n.text(scenario.cancel ? "取消" : "粘贴") }) else { return }
                    confirmed = true
                    if scenario.change {
                        expectedClipboard = "changed while confirming"
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents(); pasteboard.setString(expectedClipboard, forType: .string)
                        expectedChange = pasteboard.changeCount
                    }
                    button.performClick(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(terminal)
            guard terminal.performKeyEquivalent(with: event) else { throw WorkbenchError.message("Cmd+V 未派发") }
            timer.invalidate()
            let needsConfirmation = scenario.ask && (scenario.text.contains("\n") || scenario.text.contains("\r"))
            guard confirmed == needsConfirmation else { throw WorkbenchError.message("多行确认开关没有立即生效：\(scenario.name)") }
            let payload = scenario.cancel ? Data() : Data((scenario.bracketed ? "\u{1b}[200~" + scenario.text + "\u{1b}[201~" : scenario.text).utf8)
            try await wait { ((try? Data(contentsOf: received).count) ?? 0) >= beforeCount + payload.count }
            try await Task.sleep(for: .milliseconds(150))
            let actual = try Data(contentsOf: received).dropFirst(beforeCount)
            guard actual == payload else { throw WorkbenchError.message("tmux新窗口粘贴字节不符：\(scenario.name)，actual=\(actual.count), expected=\(payload.count)") }
            guard board.changeCount == expectedChange, board.string(forType: .string) == expectedClipboard else { throw WorkbenchError.message("粘贴改写或清空了剪贴板：\(scenario.name)") }
            if !scenario.bracketed { terminal.feed(text: "\u{1b}[<u\u{1b}[?2004h") }
            print("PASS · 真实tmux Ctrl+B C新窗口：\(scenario.name)，PTY逐字节相等且粘贴不改写剪贴板")
        }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(terminal)
        try await wait { terminal.allowsClipboardInteraction }
        for blank in ["\n", " \t\r\n", "\u{3000}"] {
            terminal.clipboard.resetPermission()
            let beforeBlank = board.changeCount
            _ = try tmux(["set-buffer", "-w", blank])
            try await wait { !terminal.clipboard.message.isEmpty }
            guard board.changeCount == beforeBlank else { throw WorkbenchError.message("真实tmux空白OSC52清空剪贴板：length=\(board.string(forType: .string)?.count ?? -1)，message=\(terminal.clipboard.message)") }
        }
        _ = try tmux(["set-buffer", "-w", "  VALID 中文\n"])
        try await wait { board.string(forType: .string) == "  VALID 中文\n" }
        print("PASS · 真实tmux仅空白OSC52不覆盖剪贴板，有效复制保留首尾空白")
        fflush(stdout)
    }
    private static func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() {
            guard Date() < deadline else { throw WorkbenchError.message("粘贴回归超时：\(line)，active=\(NSApp.isActive)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
