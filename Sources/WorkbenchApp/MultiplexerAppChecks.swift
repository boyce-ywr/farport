import AppKit
import WorkbenchCore
import OpenSSHBackend

/// 真实 App 内验证 Zellij/herdr：会话页模型、终端附着、关闭只分离、herdr 终端内新建、连接时进入。
/// 只创建随机的 farport-test-* 会话，结束时清理；不触碰其他会话。
@MainActor
enum MultiplexerAppChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let store = workspace.store
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        var targets: [HostProfile?] = [nil]
        if let loopback = store.hosts.first(where: { $0.address == "127.0.0.1" && $0.port == 22 }) { targets.append(loopback) }
        var cleanup: [(MultiplexerService, MultiplexerSession)] = []
        defer {
            workspace.cancelPreferredTmuxConnection(); workspace.sessions.forEach { workspace.close($0) }
            for (service, session) in cleanup { _ = try? service.kill(session: session) }
        }
        for (index, host) in targets.enumerated() {
            let place = host == nil ? "本机" : "回环SSH"
            let zellij = MultiplexerService(kind: .zellij, transport: store.transport, host: host)
            let herdr = MultiplexerService(kind: .herdr, transport: store.transport, host: host)
            let zellijName = "farport-test-ui-z\(index)\(suffix)", herdrName = "farport-test-ui-h\(index)\(suffix)"
            cleanup += [(zellij, MultiplexerSession(kind: .zellij, name: zellijName, running: true)), (herdr, MultiplexerSession(kind: .herdr, name: herdrName, running: true))]

            // 会话页模型：检测版本、列出会话与窗格。
            _ = try await detached { try zellij.createDetached(name: zellijName) }
            let model = MultiplexerModel(kind: .zellij, host: host, store: store)
            try await wait("\(place) Zellij 会话页未列出窗格") { await model.refresh(); return model.usable && model.sessions.contains { $0.name == zellijName && $0.running } && model.panes.contains { $0.session == zellijName } }
            let tmux = TmuxModel(host: host, store: store); await tmux.refresh()
            guard tmux.errorMessage == nil, tmux.installed != nil else { throw WorkbenchError.message("\(place) tmux 检测失败：\(tmux.errorMessage ?? "")") }
            print("PASS · \(place) 会话页检测 Zellij 并列出会话与窗格，tmux 检测正常")

            // 进入会话：终端真实附着（Zellij 报告一个客户端），关闭标签只分离。
            workspace.attachMultiplexer(host, attachment: MultiplexerAttachment(kind: .zellij, session: zellijName))
            guard let zellijTerminal = workspace.selectedTerminal, zellijTerminal.multiplexer?.session == zellijName, zellijTerminal.tmuxID == nil,
                  zellijTerminal.title.hasPrefix("Zellij · "), !zellijTerminal.terminal.semanticCommandCopyAllowed, zellijTerminal.terminal.remoteSelectionContext else {
                throw WorkbenchError.message("\(place) Zellij 标签属性不正确")
            }
            try await wait("\(place) Zellij 未附着客户端") { await clients(zellij, zellijName) > 0 }
            try snapshot(zellijTerminal.terminal.window, output: output.deletingLastPathComponent().appendingPathComponent("zellij-\(index).png"))
            workspace.close(zellijTerminal)
            try await wait("\(place) 关闭标签后 Zellij 客户端未分离") { await clients(zellij, zellijName) == 0 }
            guard try await detached({ try zellij.sessions() }).contains(where: { $0.name == zellijName && $0.running }) else { throw WorkbenchError.message("\(place) 关闭标签结束了 Zellij 会话") }
            print("PASS · \(place) Zellij 终端附着成功，关闭标签只分离、会话继续运行")

            // herdr：终端内新建并进入，关闭标签后会话仍在。
            workspace.attachMultiplexer(host, attachment: MultiplexerAttachment(kind: .herdr, session: herdrName, create: true))
            guard let herdrTerminal = workspace.selectedTerminal, herdrTerminal.multiplexer?.kind == .herdr else { throw WorkbenchError.message("\(place) herdr 标签未创建") }
            try await wait("\(place) herdr 未在终端中创建会话") { (try? await detached { try herdr.sessions() })?.contains { $0.name == herdrName && $0.running } == true }
            try await wait("\(place) herdr 会话没有工作区窗格") { let session = MultiplexerSession(kind: .herdr, name: herdrName, running: true); return ((try? await detached { try herdr.panes(of: [session]) }) ?? []).isEmpty == false }
            try snapshot(herdrTerminal.terminal.window, output: output.deletingLastPathComponent().appendingPathComponent("herdr-\(index).png"))
            workspace.close(herdrTerminal)
            try await Task.sleep(for: .seconds(1))
            guard try await detached({ try herdr.sessions() }).contains(where: { $0.name == herdrName && $0.running }) else { throw WorkbenchError.message("\(place) 关闭标签结束了 herdr 会话") }
            print("PASS · \(place) herdr 在终端中新建并进入，关闭标签后会话继续运行")

            // 连接时进入：唯一的 Zellij 会话自动进入（仅远端主机有此入口）。
            if var profile = host, let position = store.hosts.firstIndex(where: { $0.id == profile.id }) {
                let original = store.hosts[position]
                defer { store.hosts[position] = original }
                profile.entryMultiplexer = .zellij; store.hosts[position] = profile
                let others = try await detached { try zellij.sessions().filter { $0.running && $0.name != zellijName } }
                if others.isEmpty {
                    workspace.connectPreferred(profile)
                    try await wait("\(place) 连接时进入 Zellij 未自动附着") { workspace.selectedTerminal?.multiplexer?.session == zellijName && workspace.selectedTerminal?.connected == true }
                    try await wait("\(place) 连接时进入的 Zellij 未附着客户端") { await clients(zellij, zellijName) > 0 }
                    workspace.close(workspace.selectedTerminal!)
                    print("PASS · \(place) 连接时进入 Zellij：唯一会话自动附着")
                } else { print("SKIP · \(place) 已有其他 Zellij 会话，跳过唯一会话自动进入") }
            }

            // 结束会话前截取会话页（Zellij 与 herdr 会话均在运行）。
            workspace.selectedHostID = host?.id; workspace.page = .tmux
            try await Task.sleep(for: .seconds(5))
            try snapshot(NSApp.windows.first { $0.isVisible && $0.contentView != nil }, output: output.deletingLastPathComponent().appendingPathComponent("sessions-\(index)-\(L10n.language == .english ? "en" : "zh").png"))
            workspace.page = .terminal

            // 结束会话：删除记录，列表不再出现。
            try await detached { try zellij.kill(session: MultiplexerSession(kind: .zellij, name: zellijName, running: true)) }
            try await detached { try herdr.kill(session: MultiplexerSession(kind: .herdr, name: herdrName, running: true)) }
            let left = try await detached { try zellij.sessions().map(\.name) + herdr.sessions().map(\.name) }
            guard !left.contains(zellijName), !left.contains(herdrName) else { throw WorkbenchError.message("\(place) 结束会话后仍有记录") }
            print("PASS · \(place) 结束 Zellij/herdr 会话并删除记录")
        }
        workspace.selectedHostID = targets.last??.id; workspace.page = .tmux
        try await Task.sleep(for: .seconds(4))
        try snapshot(NSApp.windows.first { $0.isVisible && $0.contentView != nil }, output: output)
        if ProcessInfo.processInfo.environment["SWB_QA_COPY"] == "1" { try await checkCopy(workspace: workspace, suffix: suffix) }
    }
    /// 在窗格中用鼠标拖选（SGR 鼠标序列），确认 Zellij/herdr 自己的复制经 OSC 52 写入 Mac 剪贴板。需要 App 在前台。
    private static func checkCopy(workspace: Workspace, suffix: String) async throws {
        let store = workspace.store
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        let zellij = MultiplexerService(kind: .zellij, transport: store.transport, host: nil)
        let herdr = MultiplexerService(kind: .herdr, transport: store.transport, host: nil)
        let zellijName = "fp-copy-z" + suffix, herdrName = "fp-copy-h" + suffix
        defer {
            _ = try? zellij.kill(session: MultiplexerSession(kind: .zellij, name: zellijName, running: true))
            _ = try? herdr.kill(session: MultiplexerSession(kind: .herdr, name: herdrName, running: true))
        }
        let environment = MultiplexerService.isolatedEnvironment(try LocalShellConfiguration().environment)
        func run(_ kind: MultiplexerKind, _ command: String) async throws {
            _ = try await detached { try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", MultiplexerService.script(kind, command)], environment: environment).checked() }
        }
        for (kind, name) in [(MultiplexerKind.zellij, zellijName), (.herdr, herdrName)] {
            let marker = "FARPORT_COPY_\(kind.rawValue.uppercased())_\(suffix.uppercased())"
            if kind == .zellij {
                try await run(.zellij, "\(MultiplexerService.executableReference) attach -b '\(name)'")
                try await run(.zellij, "\(MultiplexerService.executableReference) --session '\(name)' action hide-floating-panes || :")
            }
            workspace.attachMultiplexer(nil, attachment: MultiplexerAttachment(kind: kind, session: name, create: kind == .herdr))
            guard let session = workspace.selectedTerminal, session.multiplexer?.session == name else { throw WorkbenchError.message("\(kind.title) 复制检查未打开终端") }
            try await wait("\(kind.title) 复制检查终端未显示") { session.terminal.window != nil }
            let window = session.terminal.window!
            session.terminal.clipboard.writePolicy = { .allow }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.makeFirstResponder(session.terminal)
            try await wait("\(kind.title) 复制检查需要 Farport 在前台") { session.connected && session.terminal.allowsClipboardInteraction }
            if kind == .zellij {
                try await Task.sleep(for: .seconds(2))
                session.terminal.send(txt: "\u{1b}")
                try await Task.sleep(for: .milliseconds(800))
                session.terminal.send(txt: "printf '%s\\n' \(marker)\r")
            } else {
                var pane: String?
                try await wait("herdr 复制检查没有窗格") {
                    pane = ((try? await detached { try herdr.panes(of: [MultiplexerSession(kind: .herdr, name: name, running: true)]) }) ?? []).first?.id
                    return pane != nil
                }
                try await Task.sleep(for: .seconds(2))
                try await run(.herdr, "\(MultiplexerService.executableReference) --session '\(name)' pane run '\(pane!)' \"printf '%s\\\\n' \(marker)\"")
            }
            var location: (row: Int, column: Int)?
            do {
                try await wait("\(kind.title) 输出未出现在终端画面") {
                    let screen = session.terminal.getTerminal()
                    for row in 0..<screen.rows {
                        guard let text = screen.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true),
                              let range = text.range(of: marker), !text.contains("printf") else { continue }
                        location = (row, text.distance(from: text.startIndex, to: range.lowerBound)); return true
                    }
                    return false
                }
            } catch {
                let screen = session.terminal.getTerminal()
                print((0..<screen.rows).map { "SCREEN \($0): " + (screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "") }.joined(separator: "\n"))
                throw error
            }
            let row = location!.row + 1, start = location!.column + 1, end = location!.column + marker.count + 1  // 选区终点不含所在列
            for sequence in ["\u{1b}[<0;\(start);\(row)M", "\u{1b}[<32;\(start + 4);\(row)M", "\u{1b}[<32;\(end);\(row)M", "\u{1b}[<0;\(end);\(row)m"] {
                session.terminal.send(txt: sequence); try await Task.sleep(for: .milliseconds(120))
            }
            do {
                try await wait("\(kind.title) 拖选后未经 OSC 52 写入 Mac 剪贴板", timeout: 10) { pasteboard.string(forType: .string)?.contains(marker) == true }
            } catch {
                let screen = session.terminal.getTerminal()
                print("CLIPBOARD message=\(session.terminal.clipboard.message) failed=\(session.terminal.clipboard.failed) pending=\(session.terminal.clipboard.pendingRemoteText ?? "nil") pasteboard=\(pasteboard.string(forType: .string)?.prefix(60) ?? "nil") interactive=\(session.terminal.allowsClipboardInteraction) mouseMode=\(screen.mouseMode) at row=\(row) cols=\(start)-\(end)")
                print((0..<screen.rows).map { "SCREEN \($0): " + (screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "") }.joined(separator: "\n"))
                throw error
            }
            print("PASS · 本机 \(kind.title) 鼠标拖选经 OSC 52 写入 Mac 剪贴板")
            workspace.close(session)
        }
    }
    private static func clients(_ service: MultiplexerService, _ session: String) async -> Int {
        let host = service.host, transport = service.transport
        let command = "\(MultiplexerService.executableReference) --session \(RemotePath.quote(session)) action list-clients"
        let text = await Task.detached { () -> String in
            let result: CommandResult?
            if let host { result = try? transport.run(host, command: MultiplexerService.wrap(.zellij, command)) }
            else { result = try? ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", MultiplexerService.script(.zellij, command)], environment: MultiplexerService.isolatedEnvironment((try? LocalShellConfiguration().environment) ?? [:])) }
            return result?.text ?? ""
        }.value
        return text.split(separator: "\n").dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
    private static func detached<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T { try await Task.detached { try operation() }.value }
    private static func snapshot(_ window: NSWindow?, output: URL) throws {
        guard let content = window?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw WorkbenchError.message("无法截图") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output)
    }
    private static func wait(_ failure: String, timeout: TimeInterval = 30, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) { guard Date() < deadline else { throw WorkbenchError.message(failure) }; try await Task.sleep(for: .milliseconds(300)) }
    }
}
