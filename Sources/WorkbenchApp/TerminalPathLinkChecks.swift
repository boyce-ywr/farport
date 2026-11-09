import AppKit
import WorkbenchCore
import OpenSSHBackend

/// 终端路径 Cmd+点击回归：本机与隔离 SSH 的 tmux 中输出路径，用真实鼠标事件经 SwiftTerm 识别后打开。
@MainActor
enum TerminalPathLinkChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        defer { workspace.sessions.forEach { $0.close() } }
        let hosts = [nil as HostProfile?] + workspace.store.hosts.filter { $0.address == "127.0.0.1" && [22281, 22].contains($0.port) }.map(Optional.some)
        for host in hosts {
            let transport = workspace.store.transport
            let client = try transport.files(host)
            let home = host == nil ? NSHomeDirectory() : try client.realpath(".")
            // 本机与回环 SSH（同一台 Mac）都用隔离测试目录；回环时 Docker 容器的挂载也指向它。
            let parent = host == nil || host?.port == 22 ? workspace.store.paths.root.path : home
            let name = "farport-link-" + UUID().uuidString.prefix(8).lowercased()
            let project = RemotePath.join(RemotePath.join(parent, name), "kaihua")
            let service = TmuxService(transport: transport, host: host)
            defer { try? service.kill(session: name); try? client.removeRecursively(RemotePath.join(parent, name)); client.close() }
            try client.mkdir(RemotePath.join(parent, name)); try client.mkdir(project); try client.mkdir(RemotePath.join(project, "docs"))
            let document = RemotePath.join(project, "docs/decisions.md"), image = RemotePath.join(project, "shot.png")
            try client.createFile(document); try client.saveText(document, data: Data("kaihua decisions".utf8), expected: client.stat(document), original: Data())
            try client.createFile(image); try client.saveText(image, data: try tallImage(), expected: client.stat(image), original: Data())
            // 目录用 ~ 形式（本机测试目录位于 HOME 下时），验证按目标主机 HOME 展开。
            let projectText = project.hasPrefix(home + "/") ? "~" + project.dropFirst(home.count) + "/" : project + "/"
            _ = try service.execute("new-session -d -x 120 -y 30 -s \(RemotePath.quote(name)) -c \(RemotePath.quote(project))").checked()
            guard let tmux = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("未创建路径链接测试 tmux") }
            workspace.attachTmux(host, session: tmux)
            guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("未附着路径链接测试 tmux") }
            try await wait { session.connected }
            try await wait { session.terminal.window != nil && session.terminal.frame.width > 300 }
            _ = try service.execute("send-keys -t \(RemotePath.quote(name)) -l \(RemotePath.quote("clear; printf 'DIR %s\\nDOC 已记入docs/decisions.md。\\nIMG ./shot.png:12\\nBAD docs/missing.md\\nLINK_READY\\n' \(RemotePath.quote(projectText))"))").checked()
            _ = try service.execute("send-keys -t \(RemotePath.quote(name)) Enter").checked()
            try await wait { row(starting: "LINK_READY", in: session) != nil }
            let label = host == nil ? "本机" : (host?.port == 22 ? "回环 SSH" : "SSH")

            // 不按 Cmd 的普通点击不打开。
            try click(session, prefix: "DIR ", command: false)
            try await Task.sleep(for: .milliseconds(800))
            guard workspace.page == .terminal, workspace.terminalLinkPreview == nil else { throw WorkbenchError.message("\(label)：普通点击误打开了路径") }

            // 目录 → 文件页，浏览器进入该目录。
            diagnostic = { "error=\(String(describing: workspace.store.errorMessage)) page=\(workspace.page) path=\(String(describing: workspace.currentFileBrowser?.path)) preview=\(String(describing: workspace.terminalLinkPreview?.model.previewFile?.path)) responder=\(String(describing: session.terminal.window?.firstResponder))" }
            try click(session, prefix: "DIR ")
            try await wait { workspace.page == .files && workspace.currentFileBrowser?.path == project && workspace.currentFileBrowser?.busy == false }
            workspace.page = .terminal; workspace.selectTerminal(session); session.terminal.window?.makeFirstResponder(session.terminal)
            try await wait { _ = session.terminal.window?.makeFirstResponder(session.terminal); return session.terminal.window?.firstResponder === session.terminal }

            // 中文紧贴的相对路径 → 预览浮层，焦点离开终端；关闭后焦点回到终端。
            try click(session, prefix: "DOC 已记入")
            try await wait { workspace.terminalLinkPreview?.model.previewFile?.path == document && workspace.terminalLinkPreview?.model.previewBusy == false }
            guard workspace.terminalLinkPreview?.model.previewText == "kaihua decisions" else { throw WorkbenchError.message("\(label)：预览内容不符") }
            guard session.terminal.window?.firstResponder !== session.terminal else { throw WorkbenchError.message("\(label)：预览期间键盘仍输入到终端") }
            workspace.terminalLinkPreview?.model.closeSpotlight()
            try await wait { workspace.terminalLinkPreview == nil && session.terminal.window?.firstResponder === session.terminal }

            // 带行号的图片 → 预览图片并截图；“在文件页定位”选中该文件。
            try click(session, prefix: "IMG ")
            try await wait { workspace.terminalLinkPreview?.model.previewImage != nil }
            try await Task.sleep(for: .milliseconds(500))
            if let window = session.terminal.window { try snapshot(window, output: output.deletingPathExtension().appendingPathExtension("\(host == nil ? "local" : "ssh").png")) }
            workspace.revealTerminalLinkPreview()
            try await wait { workspace.page == .files && workspace.currentFileBrowser?.selection == [image] }
            workspace.page = .terminal; workspace.selectTerminal(session)

            // 不存在的路径给出提示，不打开任何东西；右键菜单能取到同一位置的路径。
            workspace.store.errorMessage = nil
            try await wait { session.terminal.window != nil && row(starting: "BAD ", in: session) != nil && row(starting: "DOC ", in: session) != nil }
            try click(session, prefix: "BAD ")
            try await wait { workspace.store.errorMessage?.contains("docs/missing.md") == true }
            guard workspace.page == .terminal, workspace.terminalLinkPreview == nil else { throw WorkbenchError.message("\(label)：不存在的路径仍被打开") }
            workspace.store.errorMessage = nil
            guard let menuLink = session.terminal.pathLink(at: try event(session, prefix: "DOC 已记入", type: .rightMouseDown, command: false)), menuLink.contains("docs/decisions.md") else {
                throw WorkbenchError.message("\(label)：右键位置未识别出路径")
            }
            workspace.close(session)
            print("PASS · \(label) tmux：Cmd+点击目录进文件页、中文紧贴相对路径与带行号图片预览、焦点归还、定位选中、不存在路径提示、普通点击不触发、右键取路径")
            if let docker = ProcessInfo.processInfo.environment["SWB_QA_LINK_DOCKER"], !docker.isEmpty, host == nil || host?.port == 22 {
                try await containerSteps(workspace: workspace, host: host, service: service, docker: docker, name: name + "-c", project: project, label: label)
            }
        }
        fflush(stdout)
    }

    /// tmux 中 `docker exec -w /app` 进入容器：相对路径经不同路径挂载换算、同路径挂载、命名卷提示、不存在提示。
    private static func containerSteps(workspace: Workspace, host: HostProfile?, service: TmuxService, docker: String, name: String, project: String, label: String) async throws {
        let created = try ProcessRunner.run(executable: docker, arguments: ["run", "-d", "--pull=never", "--network", "none", "--label", "local.sshworkbench.fixture=true",
                                                                           "--name", name, "-v", project + ":/app", "-v", project + ":" + project, "--mount", "type=volume,dst=/root/vol",
                                                                           "--entrypoint", "/bin/sleep", "ssh-workbench-test:local", "600"], timeout: 60).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { _ = try? ProcessRunner.run(executable: docker, arguments: ["rm", "-fv", created], timeout: 60); try? service.kill(session: name) }
        _ = try service.execute("new-session -d -x 120 -y 30 -s \(RemotePath.quote(name)) -c \(RemotePath.quote(project))").checked()
        guard let tmux = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("未创建容器路径测试 tmux") }
        workspace.attachTmux(host, session: tmux)
        guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("未附着容器路径测试 tmux") }
        try await wait { session.connected && session.terminal.window != nil && session.terminal.frame.width > 300 }
        _ = try service.execute("send-keys -t \(RemotePath.quote(name)) -l \(RemotePath.quote("exec \(RemotePath.quote(docker)) exec -it -w /app \(name) sh"))").checked()
        _ = try service.execute("send-keys -t \(RemotePath.quote(name)) Enter").checked()
        try await Task.sleep(for: .seconds(2))
        // 敲入的命令保持很短：过长的命令回显会换行，clear 后残留的换行标记会让 SwiftTerm 把相邻两行拼成一个路径。
        let script = RemotePath.join(project, "p.sh"); let client = LocalFileClient(cancellation: CancellationFlag())
        try client.createFile(script); try client.saveText(script, data: Data("printf 'CDOC docs/decisions.md\\nCDIR %s/docs/\\nCVOL /root/vol/a.md\\nCBAD docs/missing.md\\nCREADY\\n' \(RemotePath.quote(project))\n".utf8), expected: client.stat(script), original: Data())
        _ = try service.execute("send-keys -t \(RemotePath.quote(name)) -l 'clear; sh p.sh'").checked()
        _ = try service.execute("send-keys -t \(RemotePath.quote(name)) Enter").checked()
        try await wait { row(starting: "CREADY", in: session) != nil }

        // 容器内相对路径 → /app/docs/decisions.md → 主机 project/docs/decisions.md，提示换算关系。
        workspace.store.taskNotice = nil; workspace.store.errorMessage = nil
        try click(session, prefix: "CDOC ")
        try await wait { workspace.terminalLinkPreview?.model.previewFile?.path == RemotePath.join(project, "docs/decisions.md") && workspace.terminalLinkPreview?.model.previewBusy == false }
        guard workspace.terminalLinkPreview?.model.previewText == "kaihua decisions", workspace.store.taskNotice?.contains("/app/docs/decisions.md") == true else {
            throw WorkbenchError.message("\(label) 容器：预览内容或路径换算提示不符：\(String(describing: workspace.store.taskNotice))")
        }
        workspace.terminalLinkPreview?.model.closeSpotlight()
        try await wait { workspace.terminalLinkPreview == nil }

        // 同路径挂载的绝对目录 → 文件页，不提示换算。
        workspace.store.taskNotice = nil
        try click(session, prefix: "CDIR ")
        try await wait { workspace.page == .files && workspace.currentFileBrowser?.path == RemotePath.join(project, "docs") && workspace.currentFileBrowser?.busy == false }
        guard workspace.store.taskNotice == nil else { throw WorkbenchError.message("\(label) 容器：同路径挂载不应提示换算") }
        workspace.page = .terminal; workspace.selectTerminal(session)

        // 命名卷路径只在容器内；不存在的路径提示未找到。
        try await wait { session.terminal.window != nil && row(starting: "CVOL", in: session) != nil }
        try click(session, prefix: "CVOL ")
        try await wait { workspace.store.errorMessage?.contains("/root/vol/a.md") == true }
        workspace.store.errorMessage = nil
        try click(session, prefix: "CBAD ")
        try await wait { workspace.store.errorMessage?.contains("docs/missing.md") == true }
        guard workspace.page == .terminal, workspace.terminalLinkPreview == nil else { throw WorkbenchError.message("\(label) 容器：失败路径仍被打开") }
        workspace.store.errorMessage = nil
        workspace.close(session)
        print("PASS · \(label) tmux → docker exec -w：容器相对路径经挂载换算后预览并提示、同路径挂载目录进文件页、命名卷与不存在路径提示")
    }

    private static func row(starting prefix: String, in session: TerminalSession) -> Int? {
        let terminal = session.terminal.getTerminal()
        return (0..<terminal.rows).first { terminal.getLine(row: $0)?.translateToString(trimRight: true).hasPrefix(prefix) == true }
    }
    /// 鼠标落在前缀之后第二个字符上；汉字按两列计算。
    private static func event(_ session: TerminalSession, prefix: String, type: NSEvent.EventType, command: Bool = true) throws -> NSEvent {
        let label = String(prefix.prefix(4))
        guard let window = session.terminal.window else { throw WorkbenchError.message("终端视图不在窗口中") }
        guard let row = row(starting: label, in: session) else { throw WorkbenchError.message("终端中找不到 \(label)") }
        let column = prefix.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 2 : 1) } + 1
        let cell = session.terminal.cellSize, frame = session.terminal.frame
        let point = session.terminal.convert(NSPoint(x: (CGFloat(column) + 0.5) * cell.width, y: frame.height - (CGFloat(row) + 0.5) * cell.height), to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw WorkbenchError.message("无法构造鼠标事件") }
        return event
    }
    private static func click(_ session: TerminalSession, prefix: String, command: Bool = true) throws {
        session.terminal.mouseDown(with: try event(session, prefix: prefix, type: .leftMouseDown, command: command))
        session.terminal.mouseUp(with: try event(session, prefix: prefix, type: .leftMouseUp, command: command))
    }
    /// 竖长截图，验证预览按窗口完整容纳。
    private static func tallImage() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 1800, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw WorkbenchError.message("无法生成测试图片") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 400, height: 1800).fill()
        NSColor.systemRed.setFill(); NSRect(x: 0, y: 0, width: 400, height: 120).fill()
        NSColor.systemYellow.setFill(); NSRect(x: 0, y: 1680, width: 400, height: 120).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw WorkbenchError.message("无法编码测试图片") }
        return data
    }
    private static func snapshot(_ window: NSWindow, output: URL) throws {
        guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw WorkbenchError.message("无法截图") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output)
    }
    private static var diagnostic: () -> String = { "" }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("终端路径链接回归超时：\(line) \(diagnostic())") }; try await Task.sleep(for: .milliseconds(70)) }
    }
}
