import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkAgentSessions() throws {
    try expect(TerminalNavigationAction.resolve(keyCode: 123, text: "", command: true, option: true, control: false, shift: false) == .previous, "外层标签Command Option Left")
    try expect(TerminalNavigationAction.resolve(keyCode: 124, text: "", command: true, option: true, control: false, shift: false) == .next, "外层标签Command Option Right")
    try expect(TerminalNavigationAction.resolve(keyCode: 0, text: "9", command: true, option: true, control: false, shift: false) == .number(9), "最后标签")
    for text in ["b", "a", "1", "j", "[", "]"] {
        try expect(TerminalNavigationAction.resolve(keyCode: 0, text: text, command: false, option: false, control: true, shift: false) == nil, "不拦截tmux Control组合")
        try expect(TerminalNavigationAction.resolve(keyCode: 0, text: text, command: false, option: true, control: false, shift: false) == nil, "不拦截Alt组合")
    }
    try expect(TerminalNavigationAction.resolve(keyCode: 0, text: "s", command: true, option: true, control: false, shift: false) == nil, "保留侧栏Command Option S")
    try expect(TerminalNavigationAction.resolve(keyCode: 0, text: "o", command: true, option: true, control: false, shift: false) == nil, "保留Option-as-Meta切换")
    try expect(TerminalNavigationAction.resolve(keyCode: 0, text: "{", command: true, option: false, control: false, shift: true) == .previous, "兼容旧切标签组合")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farport-agent-session-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("工作目录 ' $;中文")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/OpenSSHBackend/Resources/agent_sessions.py")
    let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }!
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = root.path
    environment["CODEX_HOME"] = root.appendingPathComponent(".codex").path
    environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent(".claude").path
    environment["PI_CODING_AGENT_DIR"] = root.appendingPathComponent(".pi/agent").path
    environment["PI_CODING_AGENT_SESSION_DIR"] = root.appendingPathComponent(".pi/agent/sessions").path
    var files: [CodingAgent: URL] = [:]
    var identifiers: [CodingAgent: String] = [:]
    for tool in CodingAgent.allCases {
        let identifier = UUID().uuidString
        identifiers[tool] = identifier
        let path = root.appendingPathComponent(tool == .codex ? ".codex/sessions/2026/10/20" : (tool == .claude ? ".claude/projects/fixture" : ".pi/agent/sessions/fixture"))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let file = path.appendingPathComponent(identifier + ".jsonl"); files[tool] = file
        let payload: [String: Any]
        switch tool {
        case .codex: payload = ["type": "session_meta", "payload": ["id": identifier, "cwd": directory.path, "base_instructions": "SECRET_NOT_RETURNED"]]
        case .claude: payload = ["type": "user", "sessionId": identifier, "cwd": directory.path, "message": ["content": "SECRET_NOT_RETURNED"]]
        case .pi: payload = ["type": "session", "version": 3, "id": identifier, "cwd": directory.path]
        }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(Data("\n{\"type\":\"message\",\"content\":\"SECRET_BODY_NOT_READ\"}\n".utf8))
        try data.write(to: file)
    }
    func query(_ args: [String]) throws -> CommandResult { try ProcessRunner.run(executable: python, arguments: [script.path] + args, environment: environment, timeout: 15) }
    let empty = try JSONDecoder().decode(AgentSessionListing.self, from: query([]).checked().output)
    try expect(empty.sessions.isEmpty, "未授权历史扫描不读会话文件")
    let result = try query(["--history"]).checked()
    try expect(!result.text.contains("SECRET"), "历史输出不包含聊天正文/系统指令")
    let listing = try JSONDecoder().decode(AgentSessionListing.self, from: result.output)
    try expect(listing.sessions.count == 3, "三Agent会话元数据发现")
    let codexOnly = try JSONDecoder().decode(AgentSessionListing.self, from: query(["--history", "--tool", "codex"]).checked().output)
    try expect(codexOnly.sessions.count == 1 && codexOnly.sessions[0].tool == .codex, "按Agent读取跨项目历史，不混入其他工具")
    for record in listing.sessions {
        try record.validate()
        try expect(record.sessionID == identifiers[record.tool] && record.directory == directory.path, "历史ID与真实cwd一致")
        let plan = try AgentLaunchPlan(tool: record.tool, directory: record.directory, executable: "/bin/echo", action: .resume(record))
        let captured = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", plan.command]).checked()
        try expect(captured.text.contains(record.tool == .pi ? record.file : record.sessionID), "恢复使用精确ID或Pi文件路径")
        try expect(plan.arguments.first != "--session-id" && !plan.command.contains("dangerously"), "不使用新建ID或跳过批准参数")
        let configurationKey = record.tool == .claude ? "CLAUDE_CONFIG_DIR" : (record.tool == .codex ? "CODEX_HOME" : "PI_CODING_AGENT_SESSION_DIR")
        try expect(plan.command.contains("export " + configurationKey + "="), "恢复固定原工具数据根，避免不同配置根会话串台")
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        try expect(try query(["--verify", encoded]).status == 0, "启动前重核会话元数据")
        try FileManager.default.removeItem(atPath: record.file)
        try expect(try query(["--verify", encoded]).status != 0, "历史丢失明确拒绝，不能新建代替恢复")
    }
    try rejects("目录/记录混用被拒绝") { _ = try AgentLaunchPlan(tool: listing.sessions[0].tool, directory: "/wrong", executable: "/bin/echo", action: .resume(listing.sessions[0])) }
    try rejects("相对目录被拒绝") { _ = try AgentLaunchPlan(tool: .codex, directory: ".", executable: "/bin/echo", action: .picker) }
    let link = root.appendingPathComponent(".pi/agent/sessions/fixture/link.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
    let huge = root.appendingPathComponent(".codex/sessions/2026/10/20/huge.jsonl")
    try Data(repeating: 32, count: 70000).write(to: huge)
    try Data("{\"type\":\"session_meta\",\"payload\":[]}\n".utf8).write(to: huge.deletingLastPathComponent().appendingPathComponent("invalid.jsonl"))
    let degraded = try JSONDecoder().decode(AgentSessionListing.self, from: query(["--history"]).checked().output)
    try expect(degraded.sessions.isEmpty && !degraded.notices.isEmpty, "巨大/符号链接元数据拒绝且明确列表不完整")
    print("PASS · 标签导航组合、三Agent受限元数据扫描、隐私过滤、精确恢复参数与失效历史拒绝")
}

func checkAgentRemote(root: String) throws {
    let paths = try ApplicationPaths(root: URL(fileURLWithPath: root))
    let hosts = try paths.load([HostProfile].self, from: paths.hosts)
    let transport = SSHTransport(paths: paths, noninteractive: true)
    for host in hosts where host.address == "127.0.0.1" && [22281, 22282].contains(host.port) {
        let directory = "/tmp/farport-agent-" + UUID().uuidString
        let client = try transport.files(host)
        defer { try? client.removeRecursively(directory); client.close() }
        try client.mkdir(directory)
        let executable = directory + "/agent"
        let script = "#!/bin/sh\ncase \"$*\" in *--help*) echo '--last --cd --resume --session'; exit 0;; esac\nprintf 'DIR='; pwd -P; printf 'ARG=%s\\n' \"$@\"\n"
        try client.createFile(executable)
        try client.saveText(executable, data: Data(script.utf8), expected: client.stat(executable), original: Data())
        try client.chmod(executable, permissions: 0o700)
        let catalog = AgentSessionCatalog(target: .ssh(host), transport: transport)
        let listing = try catalog.list(history: false, cancellation: CancellationFlag())
        try expect(listing.sessions.isEmpty && listing.home.hasPrefix("/"), "远端默认只探测工具和用户，不扫描历史")
        for tool in CodingAgent.allCases {
            let plan = try AgentLaunchPlan(tool: tool, directory: directory, executable: executable, action: .picker)
            let launch = try catalog.prepare(plan)
            let output = try ProcessRunner.run(executable: launch.executable, arguments: launch.arguments, environment: launch.environment, timeout: 15).checked().text
            try expect(output.contains("DIR=" + directory), "\(tool.title)远端启动的真实cwd")
            try expect(output.contains(tool == .codex ? "ARG=resume" : "ARG=--resume"), "\(tool.title)远端原生选择器参数")
        }
        let tmuxPlan = try AgentLaunchPlan(tool: .codex, directory: directory, executable: "/bin/sleep", action: .newSession)
        try rejects("短命或无效Agent启动不能伪造恢复成功") {
            let name = try catalog.createTmux(tmuxPlan, cancellation: CancellationFlag())
            let service = TmuxService(transport: transport, host: host)
            defer { try? service.kill(session: name) }
            Thread.sleep(forTimeInterval: 0.1)
            guard try service.sessions().contains(where: { $0.name == name }) else { throw WorkbenchError.message("expected exited fixture") }
        }
    }
    print("PASS · 两个隔离SSH目标的三Agent启动计划与真实PTY工作目录/参数，不读取真实会话")
}
