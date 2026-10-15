import AppKit
import Foundation
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum TerminalPreferencesChecks {
    static func run(workspace: Workspace) async throws {
        let store = workspace.store
        let originalAutomatic = store.automaticallyInsertAttachments; let originalMenu = store.useTmuxContextMenu
        let defaults = ["automaticallyInsertAttachments": UserDefaults.standard.object(forKey: "automaticallyInsertAttachments"), "useTmuxContextMenu": UserDefaults.standard.object(forKey: "useTmuxContextMenu")]
        defer {
            store.automaticallyInsertAttachments = originalAutomatic; store.useTmuxContextMenu = originalMenu
            for (key, value) in defaults { if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        }
        let source = store.paths.root.appendingPathComponent("attachment-preference.txt")
        try Data("Farport preference check\n".utf8).write(to: source)
        workspace.connectLocal()
        guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("未创建本机终端") }
        try await wait { session.connected }
        store.automaticallyInsertAttachments = false
        workspace.requestAttachments(session: session, payload: TerminalAttachmentPayload(files: [source], temporaryDirectory: nil))
        guard let draft = workspace.attachmentDraft, !draft.automaticallyInsert else { throw WorkbenchError.message("未应用手动插入策略") }
        store.automaticallyInsertAttachments = true
        try await wait { draft.result != nil || draft.failure != nil }
        guard draft.result != nil, !draft.inserted else { throw WorkbenchError.message("手动模式被全局设置变化绕过") }
        await draft.insert()
        guard draft.inserted else { throw WorkbenchError.message("手动插入失败") }
        session.terminal.process.send(data: [3][...])
        await draft.deleteUploaded(); draft.dispose(); workspace.attachmentDraft = nil
        var host = HostProfile(name: "fixture", address: "127.0.0.1"); host.attachmentInsertion = .manual
        guard !store.automaticallyInsertAttachments(for: host) else { throw WorkbenchError.message("主机手动策略未覆盖全局") }
        host.attachmentInsertion = .automatic; store.automaticallyInsertAttachments = false
        guard store.automaticallyInsertAttachments(for: host) else { throw WorkbenchError.message("主机自动策略未覆盖全局") }
        store.useTmuxContextMenu = true
        guard session.terminal.prefersTmuxMenu?() == false else { throw WorkbenchError.message("非 tmux 终端错误转发右键") }
        session.terminal.feed(text: "\r\nFARPORT_CONTEXT_MENU\r\n")
        session.terminal.selectAll()
        let clipboard = NSPasteboard.general
        let previousClipboard = clipboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            clipboard.clearContents()
            if let previousClipboard { clipboard.writeObjects(previousClipboard.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        let menu = session.terminal.ordinaryContextMenu()
        guard let copy = menu.items.first(where: { $0.title == L10n.text("复制") }), copy.isEnabled else { throw WorkbenchError.message("右键复制不可用") }
        menu.performActionForItem(at: menu.index(of: copy))
        guard clipboard.string(forType: .string)?.contains("FARPORT_CONTEXT_MENU") == true else { throw WorkbenchError.message("右键复制未写入剪贴板") }
        guard let clear = menu.items.first(where: { $0.title == L10n.text("清除选择") }) else { throw WorkbenchError.message("缺少清除选择菜单") }
        menu.performActionForItem(at: menu.index(of: clear))
        guard !session.terminal.selectionActive else { throw WorkbenchError.message("清除选择无效") }
        clipboard.clearContents(); clipboard.setString("printf '\\nFARPORT_MENU_PASTE'", forType: .string)
        let pasteMenu = session.terminal.ordinaryContextMenu()
        guard let paste = pasteMenu.items.first(where: { $0.title == L10n.text("粘贴") }), paste.isEnabled else { throw WorkbenchError.message("右键粘贴不可用") }
        let generation = session.inputGeneration
        pasteMenu.performActionForItem(at: pasteMenu.index(of: paste))
        try await wait { session.inputGeneration > generation }
        session.terminal.process.send(data: [3][...])
        guard let window = session.terminal.window else { throw WorkbenchError.message("普通终端没有窗口") }
        let point = session.terminal.convert(NSPoint(x: 80, y: 100), to: nil)
        var menuOpened = false
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let actual = note.object as? NSMenu else { return }
            menuOpened = actual.items.contains { $0.title == L10n.text("复制") } && actual.items.contains { $0.title == L10n.text("粘贴") }
            DispatchQueue.main.async { actual.cancelTracking() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
            NSApp.postEvent(event, atStart: false)
        }
        try await wait { menuOpened }
        try await checkTmuxMouse(workspace: workspace, host: nil)
        if let host = store.hosts.first(where: { $0.address == "127.0.0.1" && [22281, 22282].contains($0.port) }) { try await checkTmuxMouse(workspace: workspace, host: host) }
        workspace.selectTerminal(session)
        print("PASS · 附件策略快照、手动上传/插入、主机覆盖；普通菜单复制/粘贴/选择；tmux 会话级鼠标与右键转发")
    }
    private static func checkTmuxMouse(workspace: Workspace, host: HostProfile?) async throws {
        let service = TmuxService(transport: workspace.store.transport, host: host)
        let name = "farport-context-" + UUID().uuidString.prefix(8)
        let other = name + "-other"
        try service.create(name: name); try service.create(name: other)
        defer { try? service.kill(session: name); try? service.kill(session: other) }
        let otherBefore = try service.mouseEnabled(session: other)
        let globalBefore = try service.execute("show-options -gv mouse").checked().text
        _ = try service.execute("set-option -t \(RemotePath.quote(name)) mouse off").checked()
        guard !(try service.mouseEnabled(session: name)) else { throw WorkbenchError.message("tmux 测试初始状态错误") }
        try service.enableMouse(session: name)
        guard try service.mouseEnabled(session: name), try service.mouseEnabled(session: other) == otherBefore,
              try service.execute("show-options -gv mouse").checked().text == globalBefore else { throw WorkbenchError.message("启用鼠标改变了其他会话或全局设置") }
        guard let tmux = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("缺少 tmux 测试会话") }
        workspace.attachTmux(host, session: tmux)
        guard let terminal = workspace.selectedTerminal else { throw WorkbenchError.message("tmux 附着失败") }
        try await wait { terminal.connected && terminal.terminal.getTerminal().mouseMode != .off }
        guard terminal.terminal.prefersTmuxMenu?() == true else { throw WorkbenchError.message("tmux 右键选项未生效") }
        let inputBefore = terminal.inputGeneration
        guard let window = terminal.terminal.window else { throw WorkbenchError.message("tmux 终端未挂载窗口") }
        let point = terminal.terminal.convert(NSPoint(x: 80, y: 100), to: nil)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
                if type == .rightMouseDown {
                    terminal.terminal.rightMouseDown(with: event)
                    try await wait {
                        let screen = terminal.terminal.getTerminal()
                        return (0..<screen.rows).contains { screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).contains("Horizontal Split") == true }
                    }
                    terminal.terminal.process.send(data: [27][...])
                } else { terminal.terminal.rightMouseUp(with: event) }
            }
        }
        try await wait { terminal.inputGeneration > inputBefore }
        try await wait {
            let screen = terminal.terminal.getTerminal()
            return !(0..<screen.rows).contains { screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).contains("Horizontal Split") == true }
        }
        print("PASS · tmux 普通 Shell 右键菜单实际弹出")
        _ = try service.execute("respawn-pane -k -t \(RemotePath.quote(name)) \(RemotePath.quote("printf '\\033[2J\\033[HFARPORT_MOUSE_APP\\033[?1000h\\033[?1006h'; exec sleep 60"))").checked()
        try await wait {
            (try? service.execute("display-message -p -t \(RemotePath.quote(name)) '#{mouse_any_flag}'").checked().text.trimmingCharacters(in: .whitespacesAndNewlines)) == "1"
        }
        try await wait {
            let screen = terminal.terminal.getTerminal()
            let lines = (0..<screen.rows).map { screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "" }.joined(separator: "\n")
            return lines.contains("FARPORT_MOUSE_APP") && !lines.contains("Horizontal Split")
        }
        print("PASS · tmux 前台程序已开启鼠标模式，开始验证菜单")
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1) else { throw WorkbenchError.message("无法创建 TUI 右键事件") }
        terminal.terminal.rightMouseDown(with: event)
        try await wait {
            let screen = terminal.terminal.getTerminal()
            return (0..<screen.rows).contains { screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).contains("Horizontal Split") == true }
        }
        terminal.terminal.process.send(data: [27][...])
        if let release = NSEvent.mouseEvent(with: .rightMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) { terminal.terminal.rightMouseUp(with: release) }
        guard try service.mouseEnabled(session: other) == otherBefore, try service.execute("show-options -gv mouse").checked().text == globalBefore else { throw WorkbenchError.message("TUI 右键改变了其他会话或全局设置") }
        print("PASS · \(host == nil ? "本机" : "隔离 SSH") tmux 前台程序鼠标模式下，右键仍实际弹出菜单；不修改其他会话或全局设置")
        workspace.close(terminal)
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("终端偏好验证超时") }; try await Task.sleep(for: .milliseconds(80)) }
    }
}
