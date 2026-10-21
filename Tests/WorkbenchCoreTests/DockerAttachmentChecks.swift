import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkDockerTerminalCommands() throws {
    let parsed = try DockerTerminalCommand(arguments: ["/usr/local/bin/docker", "--context", "colima", "exec", "-it", "--user", "1000:1000", "-w", "/work dir", "-e", "TEST=value", "container-test", "sh"])
    try expect(parsed.container == "container-test" && parsed.user == "1000:1000" && parsed.context == "colima", "解析容器、用户及context，不使用窗口标题猜测")
    let attached = try DockerTerminalCommand(arguments: ["docker", "attach", "test"])
    try expect(attached.user == nil && attached.container == "test", "attach使用容器配置用户")
    let compact = try DockerTerminalCommand(arguments: ["docker", "container", "exec", "-ti", "-utester", "--workdir=/tmp", "test", "sh"])
    try expect(compact.user == "tester", "Docker选项紧凑写法")
    for flags in [["-H", "unix:///tmp/docker.sock"], ["--host=unix:///tmp/docker.sock"], ["-Hunix:///tmp/docker.sock"]] {
        let direct = try DockerTerminalCommand(arguments: ["docker"] + flags + ["exec", "-it", "test", "sh"])
        try expect(direct.connectionArguments == ["--host", "unix:///tmp/docker.sock"], "本机Unix socket显式-H/--host参数")
    }
    for endpoint in ["unix:///tmp/docker.sock", "unix:///Users/example/.colima/default/docker.sock"] {
        try DockerUnixEndpoint.validate(endpoint)
        try expect(true, "本机Unix socket可用于容器附件")
    }
    for endpoint in ["tcp://localhost:2375", "ssh://host", "https://host", "/tmp/docker.sock", "unix://remote/tmp/docker.sock", "unix:///tmp/docker.sock?host=remote", "unix:///tmp/docker.sock#fragment", "unix:///", "unix:///tmp/bad\0", "unix:///tmp/%00", "unix://user@remote/tmp/docker.sock"] {
        try rejects("不允许远程或畸形Docker地址") { try DockerUnixEndpoint.validate(endpoint) }
    }
    for flags in [["--context", "test", "--host", "unix:///tmp/docker.sock"], ["-H", "unix:///tmp/a", "-H", "unix:///tmp/b"], ["--host"], ["--host="], ["--context="]] {
        try rejects("冲突或缺失的Docker全局参数") { _ = try DockerTerminalCommand(arguments: ["docker"] + flags + ["exec", "-it", "test", "sh"]) }
    }
    for arguments in [["docker", "exec", "test", "sh"], ["docker", "exec", "-i", "test", "sh"], ["docker", "compose", "exec", "test", "sh"], ["docker", "--host", "tcp://host", "exec", "-it", "test", "sh"], ["docker", "run", "-it", "image"], ["docker", "exec", "-dit", "test", "sh"], ["docker", "exec", "-it", "--user"], ["docker", "exec", "-it", "test", "sudo", "sh"], ["docker", "exec", "-it", "../bad", "sh"], ["docker", "exec", "-it", "test"], ["docker", "attach", "--no-stdin", "test"]] {
        try rejects("不明确或不安全的Docker命令") { _ = try DockerTerminalCommand(arguments: arguments) }
    }
}

func checkDockerAttachments(arguments: [String]) throws {
    guard arguments.count == 3 else { throw WorkbenchError.message("需要docker绝对路径与两个隔离容器ID") }
    let executable = arguments[0]; let container = arguments[1]; let other = arguments[2]
    for identifier in [container, other] {
        let label = try ProcessRunner.run(executable: executable, arguments: ["inspect", "--format", "{{index .Config.Labels \"local.sshworkbench.docker-attachments\"}}", identifier]).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label == "true" else { throw WorkbenchError.message("拒绝修改非容器附件测试夹具") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farport-docker-check-" + UUID().uuidString)
    let paths = try ApplicationPaths(root: root)
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let socket = "farport-docker-check-" + UUID().uuidString
    let tmux = TmuxService(transport: transport, host: nil, socketName: socket)
    defer { _ = try? tmux.execute("kill-server"); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: paths.sockets) }
    _ = try ProcessRunner.run(executable: TmuxService.localExecutable(), arguments: ["-L", socket, "-f", "/dev/null", "new-session", "-d", "-s", "docker", "-x", "180", "-y", "40", "sleep 300"]).checked()
    let receiver = "stty -echo; printf 'FARPORT_CONTAINER_READY'; IFS= read -r line; printf '\\nFARPORT_CONTAINER_RECEIVED\\n%s\\n' \"$line\"; sleep 60"
    var launch = [executable, "exec", "-it", "--user", "tester", container, "sh", "-c", receiver]
    let endpointMode = ProcessInfo.processInfo.environment["SWB_QA_DOCKER_ENDPOINT_MODE"] ?? "context"
    if endpointMode == "host" || endpointMode == "flag" {
        let endpoint = try ProcessRunner.run(executable: executable, arguments: ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"] ).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.hasPrefix("unix:///") else { throw WorkbenchError.message("测试仅允许本机Unix socket") }
        if endpointMode == "host" { launch = ["/usr/bin/env", "-u", "DOCKER_CONTEXT", "DOCKER_HOST=" + endpoint] + launch }
        else { launch.insert(contentsOf: ["--host", endpoint], at: 1) }
    }
    let command = launch.map(RemotePath.quote).joined(separator: " ")
    _ = try tmux.execute("respawn-pane -k -t docker \(RemotePath.quote(command))").checked()
    let deadline = Date().addingTimeInterval(10)
    while !(try tmux.execute("capture-pane -p -t docker").checked().text.contains("FARPORT_CONTAINER_READY")) {
        guard Date() < deadline else { throw WorkbenchError.message("Docker终端夹具未启动") }; Thread.sleep(forTimeInterval: 0.1)
    }
    let terminal = try tmux.localDockerTerminal(session: "docker")
    try expect(LocalProcessDirectory.current(shellPID: Int32(terminal.target.processID)!) == nil, "Docker窗格目录不能作为宿主机新分屏目录")
    try rejects("未确认容器时原安全入口继续禁止docker") { _ = try tmux.target(session: "docker") }
    let selection = try DockerAttachmentDaemon.discover(terminal: terminal, cancellation: CancellationFlag())
    if endpointMode == "host" || endpointMode == "flag" {
        try expect(selection.daemon.endpoint.hasPrefix("unix:///") && selection.daemon.connectionDescription.hasPrefix("Unix socket"), "保留已识别Unix socket，不换到默认context")
    }
    try expect(selection.detectedContainerID == container, "从真实前台Docker进程匹配容器ID")
    try rejects("不能选择另一个容器") { _ = try selection.daemon.confirm(other, terminal: terminal, cancellation: CancellationFlag()) }
    let binding = try selection.daemon.confirm(container, terminal: terminal, cancellation: CancellationFlag())
    try expect(binding.user != "0:0", "使用docker exec用户而非默认root")
    let catalog = AgentSessionCatalog(target: .docker(binding), transport: transport)
    let listing = try catalog.list(history: false, cancellation: CancellationFlag())
    try expect(listing.user == binding.user.split(separator: ":").first.map(String.init) && listing.sessions.isEmpty, "Agent面板读取容器原用户，不扫描宿主历史")
    _ = try ProcessRunner.run(executable: executable, arguments: ["exec", container, "mv", "/usr/bin/python3", "/usr/bin/python3.farport-check"]).checked()
    do {
        defer { _ = try? ProcessRunner.run(executable: executable, arguments: ["exec", container, "mv", "/usr/bin/python3.farport-check", "/usr/bin/python3"]) }
        let fallback = try catalog.list(history: true, cancellation: CancellationFlag())
        try expect(fallback.sessions.isEmpty && fallback.notices.contains("python3-unavailable") && fallback.tools.count == 3, "容器缺Python时降级工具选择器，不误报空历史")
    }
    let plan = try AgentLaunchPlan(tool: .codex, directory: "/tmp", executable: "/bin/pwd", action: .newSession)
    let agentLaunch = try catalog.prepare(plan)
    let launchCommand = ([agentLaunch.executable] + agentLaunch.arguments).map(RemotePath.quote).joined(separator: " ") + "; sleep 15"
    let agentWindow = try tmux.execute("new-window -d -P -F '#{window_id}' -n agent-check -t docker: " + RemotePath.quote(launchCommand)).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
    defer { _ = try? tmux.execute("kill-window -t " + RemotePath.quote(agentWindow)) }
    let launchDeadline = Date().addingTimeInterval(10)
    var launched = ""
    repeat {
        launched = try tmux.execute("capture-pane -p -J -t " + RemotePath.quote(agentWindow)).checked().text
        if launched.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp" { break }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < launchDeadline
    try expect(launched.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp", "新容器Agent真实TTY使用容器工作目录")
    let file = root.appendingPathComponent("图片 空格'$;.png")
    let data = Data("container-attachment-".utf8) + Data(UUID().uuidString.utf8)
    try data.write(to: file)
    let folder = root.appendingPathComponent("目录 空格")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: folder.appendingPathComponent("文件.txt"))
    let uploader = DockerAttachmentUploader(binding: binding)
    let symlink = root.appendingPathComponent("attachment-link")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
    try rejects("不复制本机符号链接") { _ = try uploader.upload([symlink], transport: transport, cancellation: CancellationFlag()) { _, _ in } }
    let oversized = root.appendingPathComponent("oversized.bin")
    FileManager.default.createFile(atPath: oversized.path, contents: nil)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: 129 * 1024 * 1024); try handle.close()
    try rejects("超大文件在复制前拒绝") { _ = try uploader.upload([oversized], transport: transport, cancellation: CancellationFlag()) { _, _ in } }
    try FileManager.default.removeItem(at: oversized)
    let result = try uploader.upload([file, folder], transport: transport, cancellation: CancellationFlag()) { _, _ in }
    defer { try? uploader.cleanup(result.uploaded.directory, cancellation: CancellationFlag()) }
    let copied = try ProcessRunner.run(executable: executable, arguments: ["exec", "--user", "tester", container, "cat", result.uploaded.paths[0]]).checked().output
    try expect(copied == data && result.uploaded.fileCount == 2, "非root用户实际读取容器文件和目录，内容一致")
    let mode = try ProcessRunner.run(executable: executable, arguments: ["exec", "--user", "tester", container, "stat", "-c", "%a:%u:%g", result.uploaded.paths[0]]).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
    try expect(mode == "600:" + binding.user, "容器文件为接收用户所有且权限600")
    let directoryMode = try ProcessRunner.run(executable: executable, arguments: ["exec", "--user", "tester", container, "stat", "-c", "%a:%u:%g", result.uploaded.directory]).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
    try expect(directoryMode == "700:" + binding.user, "容器批次目录为接收用户所有且权限700")
    try rejects("禁止清理非本批附件路径") { try uploader.cleanup("/tmp", cancellation: CancellationFlag()) }
    let reference = try AttachmentReference.text(paths: result.uploaded.paths)
    try tmux.pasteDocker(reference, session: "docker", expected: terminal)
    try expect(try !tmux.execute("capture-pane -p -J -t docker").checked().text.contains("FARPORT_CONTAINER_RECEIVED"), "路径自动插入不自动回车")
    _ = try tmux.execute("send-keys -t docker Enter").checked()
    let receivedDeadline = Date().addingTimeInterval(5)
    while !(try tmux.execute("capture-pane -p -J -t docker").checked().text.contains("FARPORT_CONTAINER_RECEIVED")) {
        guard Date() < receivedDeadline else { throw WorkbenchError.message("容器没有实际接收路径") }; Thread.sleep(forTimeInterval: 0.1)
    }
    let output = try tmux.execute("capture-pane -p -J -t docker").checked().text
    try expect(output.components(separatedBy: reference.trimmingCharacters(in: .whitespacesAndNewlines)).count == 2, "原容器终端只收到一次路径")
    _ = try tmux.execute("copy-mode -t docker").checked()
    try rejects("复制模式不发送容器附件") { _ = try tmux.localDockerTerminal(session: "docker") }
    _ = try tmux.execute("send-keys -X -t docker cancel").checked()
    let extra = RemotePath.join(result.uploaded.paths[1], "unexpected.txt")
    _ = try ProcessRunner.run(executable: executable, arguments: ["exec", "--user", "tester", container, "touch", extra]).checked()
    try rejects("容器目录新增文件后不插入") { try uploader.verify(result, cancellation: CancellationFlag()) }
    _ = try ProcessRunner.run(executable: executable, arguments: ["exec", "--user", "tester", container, "rm", extra]).checked()
    _ = try ProcessRunner.run(executable: executable, arguments: ["exec", "--user", "tester", container, "sh", "-c", "printf changed > \"$1\"", "check", result.uploaded.paths[0]]).checked()
    try rejects("目标文件变化后不插入") { try uploader.verify(result, cancellation: CancellationFlag()) }
    let cancelled = CancellationFlag(); cancelled.cancel()
    try rejects("取消后不上传") { _ = try uploader.upload([file], transport: transport, cancellation: cancelled) { _, _ in } }
    _ = try tmux.execute("respawn-pane -k -t docker 'sleep 60'").checked()
    try rejects("前台Docker进程变化后不发送旧附件") { try tmux.pasteDocker(reference, session: "docker", expected: terminal) }
    try uploader.cleanup(result.uploaded.directory, cancellation: CancellationFlag())
    let missing = try ProcessRunner.run(executable: executable, arguments: ["exec", "--user", "tester", container, "test", "-e", result.uploaded.directory])
    try expect(missing.status != 0, "仅清理本批容器附件")
    _ = try ProcessRunner.run(executable: executable, arguments: ["pause", container], timeout: 10).checked()
    do {
        defer { _ = try? ProcessRunner.run(executable: executable, arguments: ["unpause", container], timeout: 10) }
        try rejects("暂停容器不上传") { try binding.daemon.validate(binding, cancellation: CancellationFlag()) }
    }
    _ = try ProcessRunner.run(executable: executable, arguments: ["restart", container], timeout: 30).checked()
    try rejects("容器重启后需要重新确认") { try binding.daemon.validate(binding, cancellation: CancellationFlag()) }
    print("PASS · 真实Docker进程识别、非root容器文件/目录复制、哈希复核、tmux定向插入且不回车、目标变化保护")
}
