import AppKit
import WorkbenchCore
import OpenSSHBackend

/// herdr 窗格前台为 docker exec 时，附件应上传到容器并插入容器内路径（本机与回环 SSH）。
/// 只使用随机 fp-att-* herdr 会话与带测试标签的容器；不触碰用户会话。
@MainActor
enum HerdrAttachmentChecks {
    static func run(workspace: Workspace) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = environment["SWB_QA_DOCKER"], let identifier = environment["SWB_QA_CONTAINER_ID"] else { throw WorkbenchError.message("需要隔离Docker附件夹具") }
        let label = try ProcessRunner.run(executable: executable, arguments: ["inspect", "--format", "{{index .Config.Labels \"local.sshworkbench.docker-attachments\"}}", identifier]).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label == "true" else { throw WorkbenchError.message("拒绝向非测试容器发送附件") }
        let store = workspace.store
        let original = store.automaticallyInsertAttachments
        defer { store.automaticallyInsertAttachments = original; workspace.attachmentDraft?.dispose(); workspace.sessions.forEach { workspace.close($0) } }
        store.automaticallyInsertAttachments = false
        var targets: [HostProfile?] = [nil]
        if let loopback = store.hosts.first(where: { $0.address == "127.0.0.1" && $0.port == 22 }) { targets.append(loopback) }
        let file = store.paths.root.appendingPathComponent("herdr 容器图片.png")
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 9, pixelsHigh: 9, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bytes = image.representation(using: .png, properties: [:]) else { throw WorkbenchError.message("无法创建图片夹具") }
        try bytes.write(to: file)
        for (index, host) in targets.enumerated() {
            let place = host == nil ? "本机" : "回环SSH"
            let service = MultiplexerService(kind: .herdr, transport: store.transport, host: host)
            let name = "fp-att-h\(index)" + String(UUID().uuidString.prefix(6)).lowercased()
            defer { _ = try? service.kill(session: MultiplexerSession(kind: .herdr, name: name, running: true)) }
            func herdr(_ arguments: String) async throws -> String {
                let command = "\(MultiplexerService.executableReference) --session '\(name)' " + arguments
                let transport = store.transport
                return try await Task.detached {
                    if let host { return try transport.run(host, command: MultiplexerService.wrap(.herdr, command)).checked().text }
                    return try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", MultiplexerService.script(.herdr, command)], environment: MultiplexerService.isolatedEnvironment(try LocalShellConfiguration().environment)).checked().text
                }.value
            }
            workspace.attachMultiplexer(host, attachment: MultiplexerAttachment(kind: .herdr, session: name, create: true))
            guard let session = workspace.selectedTerminal, session.multiplexer?.session == name else { throw WorkbenchError.message("\(place) herdr 标签未创建") }
            var pane: MultiplexerPane?
            try await wait("\(place) herdr 会话未就绪") {
                pane = (try? await Task.detached { try service.panes(of: [MultiplexerSession(kind: .herdr, name: name, running: true)]) }.value)?.first
                return pane != nil && session.connected
            }
            // 非 docker 前台：仍按附着主机处理，不误判为容器。
            let plain = try await Task.detached { try service.herdrDockerTerminal(session: name) }.value
            guard plain == nil else { throw WorkbenchError.message("\(place) 普通 Shell 窗格被误识别为 Docker") }
            let receiver = "stty -echo; printf FARPORT_CONTAINER_READY; IFS= read -r line; printf '\\nFARPORT_RECEIVED\\n%s\\n' \"$line\"; sleep 60"
            let launch = [executable, "exec", "-it", "--user", "tester", identifier, "sh", "-c", receiver].map(RemotePath.quote).joined(separator: " ")
            _ = try await herdr("pane run \(RemotePath.quote(pane!.id)) \(RemotePath.quote(launch))")
            try await wait("\(place) 容器接收程序未启动") { ((try? await herdr("pane read \(RemotePath.quote(pane!.id)) --source recent --lines 40")) ?? "").contains("FARPORT_CONTAINER_READY") }
            workspace.requestAttachments(session: session, payload: TerminalAttachmentPayload(files: [file], temporaryDirectory: nil))
            guard let draft = workspace.attachmentDraft else { throw WorkbenchError.message("\(place) 没有附件草稿") }
            try await wait("\(place) 附件未上传") { (!draft.busy && draft.result != nil) || draft.failure != nil }
            guard draft.failure == nil, draft.dockerBinding?.container.id == identifier, draft.containerSelection == nil, let result = draft.result else {
                throw WorkbenchError.message("\(place) 未识别 herdr 窗格中的容器：\(draft.failure ?? "上传到了主机")")
            }
            guard !result.paths[0].hasPrefix("/private/var"), !result.paths[0].hasPrefix("/Users/") else { throw WorkbenchError.message("\(place) 路径仍是 Mac 路径：\(result.paths[0])") }
            await draft.insert()
            guard draft.inserted, draft.failure == nil else { throw WorkbenchError.message("\(place) 插入失败：\(draft.failure ?? "")") }
            func receivedLine(_ text: String) -> Bool { text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "FARPORT_RECEIVED" } }
            try await Task.sleep(for: .seconds(1))
            guard !receivedLine((try? await herdr("pane read \(RemotePath.quote(pane!.id)) --source recent-unwrapped --lines 40")) ?? "") else { throw WorkbenchError.message("\(place) 插入后不应自动回车") }
            _ = try await herdr("pane send-keys \(RemotePath.quote(pane!.id)) enter")
            var received = ""
            try await wait("\(place) 容器程序未收到路径") {
                received = (try? await herdr("pane read \(RemotePath.quote(pane!.id)) --source recent-unwrapped --lines 40")) ?? ""
                return received.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "FARPORT_RECEIVED" }
            }
            guard received.contains((result.paths[0] as NSString).lastPathComponent) else { throw WorkbenchError.message("\(place) 容器程序收到的不是容器内路径：期望 \(result.paths[0])，收到 \(received.suffix(400))") }
            let content = try ProcessRunner.run(executable: executable, arguments: ["exec", "--user", "tester", identifier, "cat", result.paths[0]]).checked().output
            guard content == bytes else { throw WorkbenchError.message("\(place) 容器内文件内容不一致") }
            print("PASS · \(place) herdr 窗格中 docker exec：识别容器、上传到容器内 \(result.paths[0])，插入到容器程序，内容一致")
            await draft.deleteUploaded(); workspace.attachmentDraft?.dispose(); workspace.attachmentDraft = nil
            try await checkPathLinks(place: place, host: host, transport: store.transport, session: session, pane: pane!.id, herdr: herdr, executable: executable)
            workspace.close(session)
        }
    }
    /// Cmd+点击路径：普通 Shell 窗格按窗格目录解析；docker exec -w /app 时容器相对路径经 bind 挂载换算成主机路径。
    private static func checkPathLinks(place: String, host: HostProfile?, transport: SSHTransport, session: TerminalSession, pane: String, herdr: (String) async throws -> String, executable: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mounted = environment["SWB_QA_MOUNT_CONTAINER_ID"], let directory = environment["SWB_QA_MOUNT_DIR"] else { return }
        let name = session.multiplexer!.session
        func resolve(_ text: String) async throws -> TerminalPathResolution {
            guard let link = TerminalPathLink(link: text, trustedHosts: session.trustedDirectoryHosts) else { throw WorkbenchError.message("无法构造路径链接") }
            return try await Task.detached { try TerminalPathResolver.resolve(link, transport: transport, host: host, tmuxID: nil, herdr: name, shellPID: 0, reportedDirectory: nil, agentContainer: nil, cancellation: CancellationFlag()) }.value
        }
        // 普通 Shell：结束容器接收程序，回到窗格 Shell，cd 到挂载目录后点击相对路径。
        _ = try await herdr("pane send-keys \(RemotePath.quote(pane)) ctrl+c")
        try await Task.sleep(for: .seconds(1))
        _ = try await herdr("pane run \(RemotePath.quote(pane)) \(RemotePath.quote("cd " + RemotePath.quote(directory)))")
        try await Task.sleep(for: .seconds(1))
        let plain = try await resolve("probe.txt")
        guard plain.containerPath == nil, plain.file.path.hasSuffix("/probe.txt"), plain.file.path.contains((directory as NSString).lastPathComponent) else { throw WorkbenchError.message("\(place) herdr 普通窗格相对路径未按窗格目录解析：\(plain.file.path)") }
        // 容器：docker exec -w /app，容器内相对路径与绝对路径都换算到主机挂载目录。
        let launch = [executable, "exec", "-it", "-w", "/app", mounted, "sh", "-c", "sleep 60"].map(RemotePath.quote).joined(separator: " ")
        _ = try await herdr("pane run \(RemotePath.quote(pane)) \(RemotePath.quote(launch))")
        try await Task.sleep(for: .seconds(2))
        for text in ["probe.txt", "/app/probe.txt"] {
            let mapped = try await resolve(text)
            guard mapped.containerPath == "/app/probe.txt", mapped.file.path.hasSuffix((directory as NSString).lastPathComponent + "/probe.txt") else {
                throw WorkbenchError.message("\(place) herdr 容器窗格路径 \(text) 未经挂载换算：\(mapped.file.path) \(mapped.containerPath ?? "nil")")
            }
        }
        print("PASS · \(place) herdr 路径点击：普通窗格按窗格目录解析，docker exec -w /app 的相对与绝对路径经挂载换算成主机路径")
    }
    private static func wait(_ failure: String, timeout: TimeInterval = 40, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) { guard Date() < deadline else { throw WorkbenchError.message(failure) }; try await Task.sleep(for: .milliseconds(300)) }
    }
}
