import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum PreferredTmuxChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let store = workspace.store
        try await checkModel(store: store)
        guard let index = store.hosts.firstIndex(where: { $0.address == "127.0.0.1" && $0.port == 22281 }) else {
            throw WorkbenchError.message("tmux优先入口仅允许隔离SSH夹具")
        }
        let original = store.hosts[index]
        var host = original; host.prefersTmux = true; host.lastSession = "stale-session"
        store.hosts[index] = host
        let service = TmuxService(transport: store.transport, host: host)
        defer {
            workspace.cancelPreferredTmuxConnection(); workspace.sessions.forEach { workspace.close($0) }
            store.hosts[index] = original
            _ = try? service.execute("kill-server")
        }
        _ = try? service.execute("kill-server")
        workspace.connectLocal()
        try await wait { workspace.selectedTerminal?.connected == true && workspace.selectedTerminal?.terminal.window != nil }
        let window = workspace.selectedTerminal!.terminal.window!
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait { window.isKeyWindow && NSApp.isActive }
        let count = workspace.sessions.count
        workspace.connectPreferred(host)
        try await wait { workspace.preferredTmuxConnection?.loaded == true && workspace.preferredTmuxConnection?.busy == false && window.attachedSheet != nil }
        guard workspace.sessions.count == count, try service.sessions().isEmpty else { throw WorkbenchError.message("无会话时未经确认就创建了会话或终端") }
        try snapshot(window.attachedSheet!, output: output.deletingLastPathComponent().appendingPathComponent("empty.png"))
        try key("\u{1b}", code: 53, window: window.attachedSheet!)
        try await wait { workspace.preferredTmuxConnection == nil && window.attachedSheet == nil }
        guard try service.sessions().isEmpty else { throw WorkbenchError.message("取消创建仍写入远端会话") }
        print("PASS · 无远端tmux时询问创建，Esc取消不创建、不打开终端")

        workspace.connectPreferred(host)
        try await wait { workspace.preferredTmuxConnection?.loaded == true && window.attachedSheet != nil }
        try key("\r", code: 36, window: window.attachedSheet!)
        try await wait { workspace.sessions.count == count + 1 && workspace.selectedTerminal?.connected == true && window.attachedSheet == nil }
        let created = try service.sessions()
        guard created.count == 1, created[0].name == "work", workspace.selectedTerminal?.tmuxID == created[0].id else { throw WorkbenchError.message("确认创建没有进入同一个远端tmux") }
        let first = workspace.selectedTerminal!
        workspace.close(first)
        try await wait { !first.terminal.process.running }
        workspace.connectPreferred(host)
        try await wait { workspace.sessions.count == count + 1 && workspace.selectedTerminal?.connected == true && workspace.preferredTmuxConnection == nil }
        guard workspace.selectedTerminal?.tmuxID == created[0].id, try service.sessions().count == 1 else { throw WorkbenchError.message("唯一会话未自动进入或重复创建") }
        print("PASS · 确认新建后实际SSH附着，唯一会话忽略旧记录直接进入且不重复创建")
        workspace.close(workspace.selectedTerminal!)
        try await wait { window.attachedSheet == nil }

        let second = try service.createSession(name: "second")
        host.lastSession = created[0].name; store.hosts[index] = host
        workspace.connectPreferred(host)
        try await wait { workspace.preferredTmuxConnection?.sessions.count == 2 && workspace.preferredTmuxConnection?.busy == false && window.attachedSheet != nil }
        guard workspace.sessions.count == count else { throw WorkbenchError.message("多会话时绕过选择直接恢复旧会话") }
        try snapshot(window.attachedSheet!, output: output)
        guard let request = workspace.preferredTmuxConnection else { throw WorkbenchError.message("缺少会话选择请求") }
        guard let content = window.attachedSheet?.contentView, let table = table(in: content),
              let row = request.sessions.firstIndex(where: { $0.id == second.id }), table.numberOfRows == request.sessions.count else {
            throw WorkbenchError.message("无法定位实际会话列表行")
        }
        let rectangle = table.rect(ofRow: row)
        let location = table.convert(NSPoint(x: rectangle.midX, y: rectangle.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.attachedSheet!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(80))
        }
        try key("\r", code: 36, window: window.attachedSheet!)
        try await wait { workspace.selectedTerminal?.tmuxID == second.id && workspace.selectedTerminal?.connected == true && window.attachedSheet == nil }
        guard store.hosts[index].lastSession == "second" else { throw WorkbenchError.message("明确选择未保存会话记录") }
        print("PASS · 多会话展示选择且不按旧记录自动附着，选择后实际进入指定SSH会话")
        workspace.close(workspace.selectedTerminal!)

        workspace.connectPreferred(host)
        guard let cancelled = workspace.preferredTmuxConnection else { throw WorkbenchError.message("未创建检测请求") }
        workspace.page = .files
        await cancelled.refresh()
        guard workspace.preferredTmuxConnection == nil, workspace.sessions.count == count else { throw WorkbenchError.message("切换页面后迟到检测仍打开终端") }
        workspace.page = .terminal
        workspace.connectPreferred(host)
        guard let previousHost = workspace.preferredTmuxConnection else { throw WorkbenchError.message("未创建主机切换请求") }
        workspace.selectedHostID = nil
        await previousHost.refresh()
        guard workspace.preferredTmuxConnection == nil, workspace.sessions.count == count else { throw WorkbenchError.message("切换主机后旧请求仍附着") }
        workspace.connectPreferred(host)
        guard let changed = workspace.preferredTmuxConnection else { throw WorkbenchError.message("未创建配置变化请求") }
        store.hosts[index].port = 22282
        workspace.validatePreferredTmuxConnection()
        await changed.refresh()
        guard workspace.preferredTmuxConnection == nil, workspace.sessions.count == count else { throw WorkbenchError.message("主机配置变化仍打开旧端点") }
        store.hosts[index] = host
        workspace.connectPreferred(host)
        guard let earlier = workspace.preferredTmuxConnection else { throw WorkbenchError.message("未创建首次请求") }
        workspace.connectPreferred(host)
        await earlier.refresh()
        guard workspace.sessions.count == count else { throw WorkbenchError.message("重复连接的旧请求仍打开终端") }
        workspace.cancelPreferredTmuxConnection()
        try await wait { window.attachedSheet == nil }
        host.prefersTmux = false; store.hosts[index] = host
        workspace.connectPreferred(host)
        guard workspace.preferredTmuxConnection == nil, workspace.selectedTerminal?.tmuxID == nil, workspace.sessions.count == count + 1 else { throw WorkbenchError.message("关闭tmux偏好时未走普通终端") }
        try await wait { workspace.selectedTerminal?.connected == true }
        print("PASS · 页面/配置变化和重复请求取消旧检测，关闭偏好仍正常打开SSH终端")
    }

    private static func checkModel(store: AppStore) async throws {
        let service = TmuxService(transport: store.transport, host: nil, socketName: "farport-preferred-" + UUID().uuidString)
        let host = HostProfile(name: "隔离主机", address: "localhost", prefersTmux: true, lastSession: "obsolete")
        var opened: [TmuxSession] = []
        func request() -> PreferredTmuxConnection {
            let request = PreferredTmuxConnection(host: host, service: service)
            request.onConnect = { opened.append($0) }
            return request
        }
        defer { _ = try? service.execute("kill-server") }
        let empty = request(); await empty.refresh()
        guard empty.loaded, empty.sessions.isEmpty, opened.isEmpty else { throw WorkbenchError.message("零会话没有停留在确认状态") }
        await empty.create(name: "invalid:name")
        guard empty.failure != nil, opened.isEmpty, try service.sessions().isEmpty else { throw WorkbenchError.message("非法名称未阻止创建") }
        await empty.create(name: "work")
        guard opened.count == 1, opened[0].name == "work" else { throw WorkbenchError.message("显式确认未创建指定会话") }
        let single = request(); await single.refresh()
        guard opened.count == 2, opened[0].id == opened[1].id else { throw WorkbenchError.message("单会话没有自动进入") }
        let second = try service.createSession(name: "second")
        let multiple = request(); await multiple.refresh()
        guard multiple.sessions.count == 2, opened.count == 2 else { throw WorkbenchError.message("多会话自动选中了某个会话") }
        await multiple.choose(second.id)
        guard opened.count == 3, opened.last?.id == second.id else { throw WorkbenchError.message("没有进入用户选择的会话") }
        let vanished = request(); await vanished.refresh()
        try service.kill(session: second.id)
        await vanished.choose(second.id)
        guard vanished.failure != nil, opened.count == 3 else { throw WorkbenchError.message("消失的会话触发了替代附着") }
        let cancelled = request()
        let loading = Task { await cancelled.refresh() }
        await Task.yield(); cancelled.cancel(); await loading.value
        guard opened.count == 3 else { throw WorkbenchError.message("取消检测后仍附着") }
        let stale = request(); stale.isCurrent = { false }; await stale.refresh()
        guard opened.count == 3 else { throw WorkbenchError.message("失效请求仍附着") }
        try service.kill(session: opened[0].id)
        let raced = request(); await raced.refresh()
        _ = try service.createSession(name: "appeared")
        await raced.create(name: "work")
        guard raced.failure != nil, raced.sessions.count == 1, try service.sessions().count == 1 else { throw WorkbenchError.message("确认期间出现会话仍重复创建") }
        var unavailable = host; unavailable.address = "127.0.0.1"; unavailable.port = 1
        let failure = PreferredTmuxConnection(host: unavailable, service: TmuxService(transport: store.transport, host: unavailable))
        failure.onConnect = { opened.append($0) }
        await failure.refresh()
        guard failure.failure != nil, !failure.loaded, opened.count == 3 else { throw WorkbenchError.message("检测失败被当成无会话或普通终端连接") }
        print("PASS · 实际tmux零/单/多会话、明确创建、名称校验、消失/取消/陈旧请求与创建竞态")
    }
    private static func key(_ character: String, code: UInt16, window: NSWindow) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else {
            throw WorkbenchError.message("无法创建会话确认按键")
        }
        NSApp.postEvent(event, atStart: false)
    }
    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let found = table(in: child) { return found } }
        return nil
    }
    private static func snapshot(_ window: NSWindow, output: URL) throws {
        guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw WorkbenchError.message("无法截图会话确认界面") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output)
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() {
            guard Date() < deadline else { throw WorkbenchError.message("tmux优先入口回归超时：\(line)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
