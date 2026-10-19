import AppKit
import SwiftTerm
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum WorkflowRefinementChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let store = workspace.store
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        let oldNotice = store.taskNotice; let oldPreference = UserDefaults.standard.object(forKey: "notifyLongTasks")
        let oldEnabled = store.notifyLongTasks
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
            store.notifyLongTasks = oldEnabled; store.taskNotice = oldNotice
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: "notifyLongTasks") } else { UserDefaults.standard.removeObject(forKey: "notifyLongTasks") }
            workspace.sessions.forEach { $0.close() }
        }
        let terminal = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        terminal.getTerminal().resize(cols: 80, rows: 20)
        var time = Date(); var finishes: [Int?] = []
        terminal.commandCapture = SemanticCommandCapture(now: { time })
        terminal.commandCapture.completed = { elapsed, status in
            finishes.append(status)
            store.notifyTaskCompletion(title: "fixture", detail: "reported", elapsed: elapsed, background: true)
        }
        func feed(_ value: String) { terminal.dataReceived(slice: Array(value.utf8)[...]) }
        store.notifyLongTasks = true; store.taskNotice = nil
        feed("\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}echo 中文\r\n\u{1b}]133;C\u{7}")
        time = time.addingTimeInterval(35)
        feed("结果😀\r\n第二行\r\n\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
        terminal.selection.setSelection(start: Position(col: 0, row: 1), end: Position(col: 2, row: 1))
        terminal.copySemanticCommand(output: true)
        guard pasteboard.string(forType: .string) == "结果😀\n第二行" else { throw WorkbenchError.message("未能按完整标记复制Unicode输出：\(terminal.clipboard.message)") }
        terminal.copySemanticCommand(output: false)
        guard pasteboard.string(forType: .string) == "echo 中文", finishes.count == 1, store.taskNotice != nil else { throw WorkbenchError.message("命令正文、结束事件或长任务提醒错误") }
        feed("\u{1b}]133;D;0\u{7}")
        guard finishes.count == 1 else { throw WorkbenchError.message("重复结束标记产生重复提醒") }
        pasteboard.clearContents(); pasteboard.setString("KEEP", forType: .string)
        terminal.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 2, row: 3))
        terminal.copySemanticCommand(output: true)
        guard pasteboard.string(forType: .string) == "KEEP" else { throw WorkbenchError.message("跨命令选择覆盖了剪贴板") }
        terminal.feed(text: "\u{1b}[2;1Hchanged")
        terminal.selection.setSelection(start: Position(col: 0, row: 1), end: Position(col: 2, row: 1))
        terminal.copySemanticCommand(output: true)
        guard pasteboard.string(forType: .string) == "KEEP" else { throw WorkbenchError.message("已改写的缓冲行仍被复制为旧命令") }
        feed("\u{1b}[2J")
        terminal.copySemanticCommand(output: true)
        guard pasteboard.string(forType: .string) == "KEEP" else { throw WorkbenchError.message("清屏后的旧命令仍可复制") }
        store.taskNotice = nil; store.notifyLongTasks = false
        store.notifyTaskCompletion(title: "fixture", detail: "done", elapsed: 60, background: true)
        guard store.taskNotice == nil else { throw WorkbenchError.message("未启用提醒时仍打断用户") }
        store.notifyLongTasks = true
        store.notifyTaskCompletion(title: "fixture", detail: "done", elapsed: 5, background: true)
        store.notifyTaskCompletion(title: "fixture", detail: "done", elapsed: 60, background: false)
        guard store.taskNotice == nil else { throw WorkbenchError.message("短任务或当前前台任务不应提醒") }
        let base = Data("base".utf8); let edited = Data("edited".utf8)
        let first = try store.saveEditorDraft(host: nil, path: "/fixture", original: base, edited: edited, replacing: nil)
        guard try store.loadEditorDraft(host: nil, path: "/fixture") == first else { throw WorkbenchError.message("失败草稿未持久化") }
        do { _ = try store.saveEditorDraft(host: nil, path: "/fixture", original: base, edited: edited, replacing: nil); throw WorkbenchError.message("覆盖了其他编辑窗口草稿") }
        catch WorkbenchError.message(let message) where message == L10n.text("已有另一份恢复草稿，未覆盖它。请保留当前编辑内容并先处理旧草稿。") {}
        let second = try store.saveEditorDraft(host: nil, path: "/fixture", original: base, edited: Data("new".utf8), replacing: first.id)
        try store.removeEditorDraft(host: nil, path: "/fixture", identifier: first.id)
        guard try store.loadEditorDraft(host: nil, path: "/fixture") == second else { throw WorkbenchError.message("旧窗口删除了新草稿") }
        try store.removeEditorDraft(host: nil, path: "/fixture", identifier: second.id)
        guard try store.loadEditorDraft(host: nil, path: "/fixture") == nil else { throw WorkbenchError.message("保存后的草稿没有清理") }
        workspace.connectLocal()
        try await wait { workspace.selectedTerminal?.connected == true }
        guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("缺少真实PTY") }
        try await Task.sleep(for: .milliseconds(600))
        let payload = "\u{1b}c\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}printf fixture\r\n\u{1b}]133;C\u{7}LIVE OUTPUT\r\n\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}"
        let escaped = payload.utf8.map { String(format: "\\%03o", $0) }.joined()
        session.terminal.process.send(data: Array(("printf '" + escaped + "'; sleep 5\r").utf8)[...])
        try await wait { session.terminal.commandCapture.selectedText(terminal: session.terminal.getTerminal(), start: Position(col: 0, row: 1), end: Position(col: 2, row: 1), output: true) == "LIVE OUTPUT" }
        session.terminal.selection.setSelection(start: Position(col: 0, row: 1), end: Position(col: 2, row: 1))
        let menu = session.terminal.ordinaryContextMenu()
        guard let index = menu.items.firstIndex(where: { $0.title == L10n.text("复制所选命令的输出") }) else { throw WorkbenchError.message("缺少语义复制菜单") }
        menu.performActionForItem(at: index)
        guard pasteboard.string(forType: .string) == "LIVE OUTPUT" else { throw WorkbenchError.message("真实PTY到原生剪贴板的语义复制失败") }
        if let host = store.hosts.first { try await checkWeb(host: host, store: store) }
        print("PASS · 语义命令/Unicode输出复制、跨块/改写/清屏保护、真实PTY菜单复制、长任务提醒边界、私有草稿持久化与并发保护")
        fflush(stdout)
    }
    private static func checkWeb(host: HostProfile, store: AppStore) async throws {
        guard ["127.0.0.1", "localhost", "::1"].contains(host.address), host.jumpHost.isEmpty else { throw WorkbenchError.message("网页回归仅接受隔离本机SSH服务器") }
        let script = """
        import os, signal, socket
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        server = socket.socket()
        server.bind(('127.0.0.1', 0))
        server.listen(1)
        port = server.getsockname()[1]
        child = os.fork()
        if child:
            print(port, flush=True)
            server.close()
        else:
            os.setsid()
            null = os.open('/dev/null', os.O_RDWR)
            for descriptor in (0, 1, 2): os.dup2(null, descriptor)
            signal.alarm(20)
            connection, address = server.accept()
            connection.settimeout(5)
            request = b''
            while b'\\r\\n\\r\\n' not in request and len(request) < 65536:
                chunk = connection.recv(4096)
                if not chunk: break
                request += chunk
            body = b'FARPORT_WEB_OK'
            connection.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: ' + str(len(body)).encode() + b'\\r\\nConnection: close\\r\\n\\r\\n' + body)
            connection.close()
            server.close()
        """
        let transport = store.transport
        let result = try await Task.detached { try transport.run(host, command: "python3 -c " + RemotePath.quote(script), timeout: 20).checked() }.value
        guard let port = Int(result.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw WorkbenchError.message("HTTP测试服务未返回端口") }
        let service = ForwardedService(hostID: host.id, connectionKey: host.connectionKey, name: "fixture", port: port)
        var localURL: URL?
        let session = try WebServiceSession(host: host, service: service, transport: transport) { url in localURL = url; return true }
        defer { session.stop() }
        try await wait { localURL != nil || !session.running }
        guard let localURL else { throw WorkbenchError.message(session.state) }
        let (data, response) = try await URLSession.shared.data(from: localURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, String(decoding: data, as: UTF8.self) == "FARPORT_WEB_OK" else { throw WorkbenchError.message("SSH网页通道返回内容不正确") }
        session.stop()
        guard !session.running else { throw WorkbenchError.message("网页通道未停止") }
        print("PASS · 真实隔离SSH认证→动态回环端口→HTTP请求响应→独立通道停止；未打开外部浏览器")
    }
    private static func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw WorkbenchError.message("二期工作流原生验收等待超时：第 \(line) 行")
    }
}
