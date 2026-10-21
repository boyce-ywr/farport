import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum AgentWorkspaceChecks {
    static func runModels(workspace: Workspace) async throws {
        let store = workspace.store
        defer { workspace.sessions.forEach { $0.close() } }
        workspace.connectLocal()
        guard let original = workspace.selectedTerminal else { throw WorkbenchError.message("没有原终端") }
        try await wait { original.connected }
        let input = store.paths.root.appendingPathComponent("original-input")
        original.terminal.send(txt: "stty -echo -icanon; : > \(RemotePath.quote(input.path)); printf '\\nAGENT_MODELS_READY\\n'; cat >> \(RemotePath.quote(input.path))\n")
        try await wait { hasLine("AGENT_MODELS_READY", in: original) }
        let catalog = AgentSessionCatalog(target: .local, transport: store.transport)
        let cwd = store.paths.root.appendingPathComponent("model-agent cwd")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let executable = cwd.appendingPathComponent("fake-agent")
        let result = cwd.appendingPathComponent("result")
        let script = "#!/bin/sh\ncase \"$*\" in *--help*) printf '%s\\n' '--last --cd --resume --session'; exit 0;; esac\nprintf '%s\\n' \"$PWD\" \"$@\" > \(RemotePath.quote(result.path))\nsleep 120\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let plan = try AgentLaunchPlan(tool: .codex, directory: cwd.path, executable: executable.path, action: .picker)
        let name = try await Task.detached { try catalog.createTmux(plan, cancellation: CancellationFlag()) }.value
        let service = TmuxService(transport: store.transport, host: nil)
        defer { try? service.kill(session: name) }
        workspace.launchAgent(catalog: catalog, plan: plan, key: "model-record", tmux: name)
        guard let launched = workspace.selectedTerminal else { throw WorkbenchError.message("没有新Agent终端") }
        try await wait { launched.connected && (try? String(contentsOf: result, encoding: .utf8).contains("resume")) == true }
        guard try Data(contentsOf: input).isEmpty, launched !== original else { throw WorkbenchError.message("Agent启动影响原前台输入") }
        let model = AgentSessionsModel(workspace: workspace)
        await model.refresh()
        guard model.failure == nil, model.directory == cwd.path, model.listing?.sessions.isEmpty == true,
              model.running.contains(where: { $0.id == launched.id }) else { throw WorkbenchError.message(model.failure ?? "面板目标、目录或运行登记未保留") }
        let before = try Data(contentsOf: result)
        let sessions = workspace.sessions.count
        launched.reconnect()
        try await wait { launched.connected }
        try await Task.sleep(for: .milliseconds(200))
        guard workspace.sessions.count == sessions, try Data(contentsOf: result) == before else { throw WorkbenchError.message("重新附着重复运行Agent命令") }
        model.stop()
        let oldCount = workspace.sessions.count
        let cancelled = await model.launch(.newSession)
        guard !cancelled, workspace.sessions.count == oldCount else { throw WorkbenchError.message("取消后仍启动Agent") }
        try service.kill(session: name)
        try await wait { !launched.connected }
        launched.reconnect()
        try await wait { !launched.connecting }
        guard !launched.connected, try !service.sessions().contains(where: { $0.name == name }) else { throw WorkbenchError.message("失效tmux会话被静默重建") }
        print("PASS · Agent模型链路：新tmux启动、原终端零输入、目录/运行登记、只附着不重跑、取消和失效会话拒绝；不代替前台键盘验收")
        fflush(stdout)
    }
    static func run(workspace: Workspace, output: URL) async throws {
        let store = workspace.store
        var terminals: [TerminalSession] = []
        var destinations: [URL] = []
        defer { workspace.showAgentSessions = false; workspace.sessions.forEach { $0.close() } }
        for index in 0..<2 {
            workspace.connectLocal()
            guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("没有导航测试终端") }
            try await wait { session.connected && session.terminal.window != nil }
            let file = store.paths.root.appendingPathComponent("nav-input-\(index)")
            destinations.append(file); terminals.append(session)
            session.terminal.send(txt: "stty -echo -icanon; : > \(RemotePath.quote(file.path)); printf '\\nNAV_READY_\(index)\\n'; cat >> \(RemotePath.quote(file.path))\n")
            try await wait { hasLine("NAV_READY_\(index)", in: session) }
            session.terminal.feed(text: "\u{1b}[>11u")
        }
        guard let window = terminals[0].terminal.window else { throw WorkbenchError.message("没有测试窗口") }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait { NSApp.isActive && window.isKeyWindow }
        workspace.selectTerminal(terminals[0])
        try await key(code: 124, text: "\u{f703}", modifiers: [.command, .option, .function, .numericPad], window: window)
        guard workspace.selectedTerminal === terminals[1] else { throw WorkbenchError.message("Command Option Right未切换标签") }
        try await key(code: 18, text: "1", modifiers: [.command, .option, .capsLock], window: window)
        guard workspace.selectedTerminal === terminals[0] else { throw WorkbenchError.message("Command Option数字未切回指定标签") }
        try await key(code: 25, text: "9", modifiers: [.command, .option], window: window)
        guard workspace.selectedTerminal === terminals[1] else { throw WorkbenchError.message("最后标签未选择") }
        try await key(code: 23, text: "5", modifiers: [.command, .option], window: window)
        guard workspace.selectedTerminal === terminals[1] else { throw WorkbenchError.message("不存在的标签不应切换") }
        try await key(code: 33, text: "{", modifiers: [.command, .shift], window: window)
        guard workspace.selectedTerminal === terminals[0] else { throw WorkbenchError.message("旧标签快捷键不兼容") }
        try await key(code: 124, text: "\u{f703}", modifiers: [.command, .option], window: window, repeated: true)
        try await Task.sleep(for: .milliseconds(150))
        for file in destinations { guard try Data(contentsOf: file).isEmpty else { throw WorkbenchError.message("标签快捷键或松键事件泄漏到PTY") } }
        let selected = workspace.selectedTerminalID
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        window.contentView?.addSubview(input); window.makeFirstResponder(input)
        try await key(code: 123, text: "\u{f702}", modifiers: [.command, .option], window: window)
        guard workspace.selectedTerminalID == selected else { throw WorkbenchError.message("文本框内导航快捷键抢夺焦点") }
        input.removeFromSuperview()
        workspace.selectTerminal(terminals[0])
        try await key(code: 38, text: "j", modifiers: [.command, .option], window: window)
        try await wait { workspace.showAgentSessions && window.attachedSheet != nil }
        try await Task.sleep(for: .seconds(1))
        if let content = window.attachedSheet?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        workspace.showAgentSessions = false
        try await wait { window.attachedSheet == nil }
        let cwd = store.paths.root.appendingPathComponent("agent cwd 空格 '")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let received = cwd.appendingPathComponent("launched.txt")
        let executable = cwd.appendingPathComponent("fake-agent")
        let content = "#!/bin/sh\ncase \"$*\" in *--help*) printf '%s\\n' '--last --cd --resume --session'; exit 0;; esac\n/bin/pwd -P > \(RemotePath.quote(received.path))\nprintf '%s\\n' \"$@\" >> \(RemotePath.quote(received.path))\nsleep 10\n"
        try content.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let plan = try AgentLaunchPlan(tool: .codex, directory: cwd.path, executable: executable.path, action: .picker)
        let catalog = AgentSessionCatalog(target: .local, transport: store.transport)
        let before = workspace.sessions.count
        workspace.launchAgent(catalog: catalog, plan: plan, key: "fixture")
        try await wait { (try? String(contentsOf: received, encoding: .utf8).contains("resume")) == true }
        guard workspace.sessions.count == before + 1, let launched = workspace.selectedTerminal, launched !== terminals[0], launched !== terminals[1] else { throw WorkbenchError.message("Agent启动替换了原终端") }
        let text = try String(contentsOf: received, encoding: .utf8)
        guard text.contains(cwd.lastPathComponent), text.contains("resume") else { throw WorkbenchError.message("Agent进程cwd或参数不正确") }
        for file in destinations { guard try Data(contentsOf: file).isEmpty else { throw WorkbenchError.message("启动Agent向原进程注入了命令") } }
        let model = AgentSessionsModel(workspace: workspace)
        await model.refresh()
        guard model.target?.identity == catalog.target.identity, model.directory == plan.directory, model.listing?.sessions.isEmpty == true else { throw WorkbenchError.message("面板目标/工作目录未继承或默认读取了历史") }
        print("PASS · 外层标签真实按下/连发/松键无PTY泄漏、文本框保护、Agent面板快捷键与新标签进程cwd/参数隔离")
        fflush(stdout)
    }
    private static func key(code: UInt16, text: String, modifiers: NSEvent.ModifierFlags, window: NSWindow, repeated: Bool = false) async throws {
        let modifierKeys: [(UInt16, NSEvent.ModifierFlags)] = [(58, .option), (56, .shift), (55, .command)]
        var held: NSEvent.ModifierFlags = []
        for (keyCode, flag) in modifierKeys where modifiers.contains(flag) {
            held.insert(flag)
            if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: held, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        let events: [(NSEvent.EventType, Bool)] = repeated ? [(.keyDown, false), (.keyDown, true), (.keyUp, false)] : [(.keyDown, false), (.keyUp, false)]
        for (type, repeatEvent) in events {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: type == .keyUp ? [] : modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                               characters: text, charactersIgnoringModifiers: text, isARepeat: repeatEvent, keyCode: code) else { throw WorkbenchError.message("无法创建导航事件") }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(100))
        }
        for (keyCode, flag) in modifierKeys.reversed() where modifiers.contains(flag) {
            held.remove(flag)
            if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: held, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    private static func hasLine(_ text: String, in session: TerminalSession) -> Bool {
        let terminal = session.terminal.getTerminal()
        return (0..<terminal.rows).contains { terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).trimmingCharacters(in: .whitespacesAndNewlines) == text }
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("Agent/导航界面超时：\(line)，active=\(NSApp.isActive)") }; try await Task.sleep(for: .milliseconds(70)) }
    }
}
