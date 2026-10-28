import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum TmuxCopyChecks {
    static func run(store: AppStore) async throws {
        try await run(store: store, host: nil)
        if ProcessInfo.processInfo.environment["SWB_QA_REQUIRE_SSH"] == "1" {
            guard let host = store.hosts.first(where: { $0.address == "127.0.0.1" && $0.port == 22281 }) else { throw WorkbenchError.message("tmux 复制测试仅允许隔离 SSH 主机") }
            try await run(store: store, host: host)
        }
    }
    private static func run(store: AppStore, host: HostProfile?) async throws {
        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            board.clearContents()
            if let previous { board.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        let socket = "farport-copy-" + UUID().uuidString
        let executable = try TmuxService.localExecutable()
        let service = TmuxService(transport: store.transport, host: host, socketName: socket)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
        environment["TERM"] = "xterm-256color"
        func tmux(_ arguments: [String]) throws -> String {
            if host != nil { return try service.execute(arguments.map(RemotePath.quote).joined(separator: " ")).checked().text.trimmingCharacters(in: .newlines) }
            return try ProcessRunner.run(executable: executable, arguments: ["-L", socket] + arguments, environment: environment, timeout: 5).checked().text.trimmingCharacters(in: .newlines)
        }
        defer { _ = try? tmux(["kill-server"]) }
        let expected = "COPY_TMUX_中文_" + UUID().uuidString
        _ = try tmux(["-f", "/dev/null", "new-session", "-d", "-s", "copy-check", "-x", "100", "-y", "24", "printf '%s\\n' " + RemotePath.quote(expected) + "; sleep 120"])
        _ = try tmux(["set-option", "-s", "set-clipboard", "off"])
        _ = try tmux(["set-option", "-g", "mouse", "on"])
        _ = try tmux(["set-window-option", "-t", "copy-check", "mode-keys", "emacs"])
        _ = try tmux(["set-buffer", "-b", "unrelated", "STALE_OTHER_PANE"])
        let terminal = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        terminal.remoteSelectionContext = true
        let sessionID = try tmux(["display-message", "-p", "-t", "copy-check", "#{session_id}"])
        terminal.copyRemoteSelection = { cancellation in
            try await Task.detached { try service.copySelection(session: sessionID, cancellation: cancellation) }.value
        }
        terminal.clipboard.writePolicy = { .allow }
        let window = NSWindow(contentRect: terminal.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = terminal; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(terminal)
        if let host {
            let command = RemoteTmuxCommand.wrap("exec " + RemoteTmuxCommand.executableReference + " -L " + RemotePath.quote(socket) + " attach-session -t copy-check")
            terminal.startProcess(executable: "/usr/bin/ssh", args: try store.transport.options(for: host) + ["-tt", host.address, command], environment: store.transport.environment(for: host).map { "\($0.key)=\($0.value)" })
        } else { terminal.startProcess(executable: executable, args: ["-L", socket, "attach-session", "-t", "copy-check"], environment: environment.map { "\($0.key)=\($0.value)" }) }
        defer { terminal.process.terminate(); window.orderOut(nil) }
        try await wait {
            let screen = terminal.getTerminal()
            return terminal.process.running && terminal.allowsClipboardInteraction && (0..<screen.rows).contains { screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).contains(expected) == true }
        }
        _ = try tmux(["copy-mode", "-t", "copy-check"])
        for action in ["history-top", "start-of-line", "begin-selection", "end-of-line"] {
            _ = try tmux(["send-keys", "-t", "copy-check", "-X", action])
        }
        guard try tmux(["display-message", "-p", "-t", "copy-check", "#{selection_present}"]) == "1", terminal.getSelection() == nil || terminal.getSelection() == "" else {
            throw WorkbenchError.message("夹具必须有真实 tmux 选区且没有本地选区")
        }
        board.clearContents(); board.setString("KEEP_MAC_CLIPBOARD", forType: .string)
        try copy(terminal)
        try await wait { terminal.clipboard.message != L10n.text("正在复制 tmux 选区…") }
        guard board.string(forType: .string) == expected else {
            throw WorkbenchError.message("真实 tmux 已选中但关闭 OSC52 时 ⌘C 未复制：\(terminal.clipboard.message)")
        }
        guard try tmux(["display-message", "-p", "-t", "copy-check", "#{selection_present}"]) == "1" else { throw WorkbenchError.message("复制不应清除 tmux 选区或退出复制模式") }
        guard try tmux(["show-buffer", "-b", "unrelated"]) == "STALE_OTHER_PANE" else { throw WorkbenchError.message("复制不应读写其他 tmux 缓冲区") }
        guard try !tmux(["list-buffers", "-F", "#{buffer_name}"]).contains("farport-copy-") else { throw WorkbenchError.message("复制后遗留内部 tmux 缓冲区") }
        let mode = try tmux(["show-options", "-sv", "set-clipboard"])
        guard mode == "off" else { throw WorkbenchError.message("主动复制修改了 tmux 剪贴板配置") }
        _ = try tmux(["set-option", "-s", "set-clipboard", "on"])
        if host == nil {
            terminal.clipboard.writePolicy = { .deny }
            board.clearContents(); board.setString("KEEP_MODERN", forType: .string)
            try copy(terminal)
            try await wait { terminal.clipboard.message != L10n.text("正在复制 tmux 选区…") }
            guard board.string(forType: .string) == expected else { throw WorkbenchError.message("新 tmux 显式选区复制未独立于后台OSC52权限") }
            try await Task.sleep(for: .milliseconds(150))
            guard !terminal.clipboard.failed else { throw WorkbenchError.message("主动复制重复触发远端 OSC52 权限提示") }
        } else {
            board.clearContents(); board.setString("KEEP_LEGACY", forType: .string)
            do { _ = try service.copySelection(session: sessionID); throw WorkbenchError.message("旧tmux开启OSC52时不应触发无法取消的复制副作用") }
            catch let error as WorkbenchError {
                guard error.localizedDescription == L10n.text("当前 tmux 无法独立读取选区；请用 Shift 拖选后 ⌘C 复制。") else { throw error }
            }
            guard board.string(forType: .string) == "KEEP_LEGACY" else { throw WorkbenchError.message("旧 tmux 的不安全回退改写了剪贴板") }
        }
        _ = try tmux(["set-option", "-s", "set-clipboard", "off"])
        let menu = terminal.ordinaryContextMenu()
        guard let menuItem = menu.items.first(where: { $0.title == L10n.text("复制") }), menuItem.isEnabled else { throw WorkbenchError.message("tmux 远端选区的右键复制仍被禁用") }
        _ = try tmux(["send-keys", "-t", "copy-check", "-X", "cancel"])
        board.clearContents(); board.setString("DO_NOT_COPY_OLD_BUFFER", forType: .string)
        try copy(terminal)
        try await wait { terminal.clipboard.message != L10n.text("正在复制 tmux 选区…") }
        guard board.string(forType: .string) == "DO_NOT_COPY_OLD_BUFFER", terminal.clipboard.informational else { throw WorkbenchError.message("没有 tmux 选区时误取了历史缓冲区") }
        let cancelled = CancellationFlag(); cancelled.cancel()
        do { _ = try service.copySelection(session: sessionID, cancellation: cancelled); throw WorkbenchError.message("已取消的复制仍然读取 tmux") }
        catch WorkbenchError.cancelled {}
        let cell = terminal.cellSizeInPixels(source: terminal.getTerminal())!
        let scale = window.backingScaleFactor
        let selected = "COPY_TMUX"
        for delay in [100, 0] {
            if host == nil, delay == 0 {
                _ = try tmux(["set-option", "-s", "set-clipboard", "on"])
                terminal.clipboard.writePolicy = { .allow }
            }
            board.clearContents(); board.setString("KEEP_BEFORE_MOUSE", forType: .string)
            var releasedAt: TimeInterval = 0
            for (type, column) in [(NSEvent.EventType.leftMouseDown, 0), (.leftMouseDragged, 0), (.leftMouseDragged, selected.count), (.leftMouseUp, selected.count)] {
                let point = terminal.convert(NSPoint(x: CGFloat(column * cell.width) / scale + 1, y: terminal.bounds.height - CGFloat(cell.height) / scale / 2), to: nil)
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                if type == .leftMouseDown { terminal.mouseDown(with: event) }
                else if type == .leftMouseUp { releasedAt = ProcessInfo.processInfo.systemUptime; terminal.mouseUp(with: event) }
                else { terminal.mouseDragged(with: event) }
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            }
            try await wait { (try? tmux(["display-message", "-p", "-t", "copy-check", "#{pane_in_mode}"])) == "0" }
            print(String(format: "PERF · %@ 拖选间隔%dms，鼠标释放完成 %.3fs", host == nil ? "本机" : "SSH", delay, ProcessInfo.processInfo.systemUptime - releasedAt))
            if host == nil, delay == 0 {
                try await wait { board.string(forType: .string) == selected }
                try await Task.sleep(for: .milliseconds(2200))
            }
            try copy(terminal)
            try await wait { terminal.clipboard.message != L10n.text("正在复制 tmux 选区…") }
            guard board.string(forType: .string) == selected else { throw WorkbenchError.message("鼠标松开后⌘C没有复制本次拖选：\(terminal.clipboard.message)，夹具结果=\(board.string(forType: .string) ?? "nil")") }
            let changeCount = board.changeCount
            let currentMenu = terminal.ordinaryContextMenu()
            guard let copyIndex = currentMenu.items.firstIndex(where: { $0.title == L10n.text("复制") }) else { throw WorkbenchError.message("拖选后缺少复制菜单") }
            currentMenu.performActionForItem(at: copyIndex)
            try await wait { board.changeCount != changeCount }
            guard board.string(forType: .string) == selected else { throw WorkbenchError.message("菜单复制丢失了松开后的拖选快照") }
        }
        if host == nil { print("PASS · 鼠标松开触发OSC52后，超过近期同步提示期限仍能显式复制同一快照") }
        try await checkLateResults()
        try await checkDragSnapshots()
        print("PASS · \(host == nil ? "本机" : "隔离 SSH") 真实 tmux 选区关闭 OSC52 后 ⌘C 仍复制，保留选区、不取旧缓冲区、无内部缓冲残留")
    }
    private static func checkDragSnapshots() async throws {
        let board = NSPasteboard.general
        for scenario in ["copy", "input", "pending-input", "reset", "clipboard", "focus", "empty", "timeout"] {
            let state = TerminalClipboardState()
            board.clearContents(); board.setString("KEEP_DRAG", forType: .string)
            var releases = 0
            state.captureDragSelection(read: { _ in
                try? await Task.sleep(for: .milliseconds(scenario == "timeout" ? 2300 : 80))
                if scenario == "empty" { return nil }
                return Data("DRAG_SNAPSHOT".utf8)
            }, isStillInteractive: { true }, release: { releases += 1 })
            if scenario == "copy" {
                state.copyTmuxSelection(read: { _ in throw WorkbenchError.message("拖选快照不应回退到历史缓冲区") }, isStillInteractive: { true })
                try await wait { board.string(forType: .string) == "DRAG_SNAPSHOT" }
                guard releases == 1 else { throw WorkbenchError.message("读取快照后没有释放鼠标") }
                let changeCount = board.changeCount
                state.copyTmuxSelection(read: { _ in throw WorkbenchError.message("连续复制不应丢弃本次拖选快照") }, isStillInteractive: { true })
                try await wait { board.changeCount != changeCount }
                guard board.string(forType: .string) == "DRAG_SNAPSHOT", releases == 1 else { throw WorkbenchError.message("连续复制快照失败或重复释放鼠标") }
            } else {
                try await Task.sleep(for: .milliseconds(scenario == "pending-input" ? 20 : 120))
                guard board.string(forType: .string) == "KEEP_DRAG" else { throw WorkbenchError.message("未显式复制时拖选改写了剪贴板") }
                switch scenario {
                case "input", "pending-input": state.noteUserInteraction()
                case "reset": state.resetPermission()
                case "clipboard": board.clearContents(); board.setString("OTHER_COPY", forType: .string)
                case "focus": NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
                case "timeout": try await Task.sleep(for: .milliseconds(2300))
                default: break
                }
                state.copyTmuxSelection(read: { _ in nil }, isStillInteractive: { true })
                try await wait { state.message != L10n.text("正在复制 tmux 选区…") }
                try await Task.sleep(for: .milliseconds(100))
                guard board.string(forType: .string) == (scenario == "clipboard" ? "OTHER_COPY" : "KEEP_DRAG"), releases == 1 else {
                    throw WorkbenchError.message("拖选快照失效或鼠标释放保护失败：\(scenario)")
                }
            }
            state.resetPermission()
        }
        print("PASS · 松开鼠标前快照、等待中的⌘C、失焦/输入/连接/剪贴板失效及2秒释放上限")
    }
    private static func checkLateResults() async throws {
        let board = NSPasteboard.general
        for scenario in ["input", "reset", "inactive", "clipboard", "new-copy", "window"] {
            let state = TerminalClipboardState()
            board.clearContents(); board.setString("KEEP", forType: .string)
            var interactive = true
            state.copyTmuxSelection(read: { _ in try? await Task.sleep(for: .milliseconds(200)); return Data("STALE".utf8) }, isStillInteractive: { interactive })
            try await Task.sleep(for: .milliseconds(30))
            switch scenario {
            case "input": state.noteUserInteraction()
            case "reset": state.resetPermission()
            case "inactive": interactive = false
            case "clipboard": board.clearContents(); board.setString("OTHER", forType: .string)
            case "new-copy": state.copyTmuxSelection(read: { _ in Data("NEW".utf8) }, isStillInteractive: { true })
            case "window": NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: NSApp.keyWindow)
            default: break
            }
            try await Task.sleep(for: .milliseconds(270))
            let expected = scenario == "clipboard" ? "OTHER" : (scenario == "new-copy" ? "NEW" : "KEEP")
            guard board.string(forType: .string) == expected else { throw WorkbenchError.message("异步复制迟到覆盖：" + scenario) }
            state.resetPermission()
        }
        for data in [Data(), Data([0xff]), Data(repeating: 65, count: 1024 * 1024 + 1)] {
            let state = TerminalClipboardState()
            board.clearContents(); board.setString("KEEP", forType: .string)
            state.copyTmuxSelection(read: { _ in data }, isStillInteractive: { true })
            try await Task.sleep(for: .milliseconds(100))
            guard state.failed, board.string(forType: .string) == "KEEP" else { throw WorkbenchError.message("无效 tmux 选区覆盖剪贴板") }
        }
        print("PASS · 新输入、连接重置、失焦、新复制和剪贴板变化均拦截迟到结果，空内容/编码/大小限制生效")
    }
    private static func copy(_ terminal: SafeTerminalView) throws {
        guard let window = terminal.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8),
              terminal.performKeyEquivalent(with: event) else { throw WorkbenchError.message("⌘C 未派发至原终端") }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("tmux 复制夹具就绪超时") }; try await Task.sleep(for: .milliseconds(50)) }
    }
}
