import Foundation
import Darwin
import WorkbenchCore

public struct TerminalProcessLaunch: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String?
    public init(executable: String, arguments: [String], environment: [String: String], directory: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.directory = directory
    }
}

public enum AgentExecutionTarget: Sendable {
    case local
    case ssh(HostProfile)
    case docker(DockerAttachmentBinding)

    public var identity: String {
        switch self {
        case .local: return "local:" + NSUserName()
        case .ssh(let host): return host.id.uuidString + ":" + host.connectionKey
        case .docker(let binding): return "docker:" + binding.daemon.identifier + ":" + binding.container.id + ":" + binding.container.started + ":" + binding.user
        }
    }
    public var label: String {
        switch self {
        case .local: return L10n.text("此 Mac") + " · " + NSUserName()
        case .ssh(let host): return host.name + " · " + host.username
        case .docker(let binding): return "Docker · " + binding.container.displayName + " · " + binding.user
        }
    }
    public var host: HostProfile? { if case .ssh(let host) = self { return host }; return nil }
}

public struct AgentSessionCatalog: Sendable {
    public let target: AgentExecutionTarget
    public let transport: SSHTransport
    public init(target: AgentExecutionTarget, transport: SSHTransport) { self.target = target; self.transport = transport }
    public static func localForegroundCommand(shellPID: Int32) throws -> String {
        var shell = proc_bsdinfo()
        guard shellPID > 0, proc_pidinfo(shellPID, PROC_PIDTBSDINFO, 0, &shell, Int32(MemoryLayout.size(ofValue: shell))) == MemoryLayout.size(ofValue: shell), shell.pbi_uid == getuid() else {
            throw WorkbenchError.message(L10n.text("当前执行环境未确认，请使用实际主机或容器连接。"))
        }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(Int32(bitPattern: shell.e_tpgid), &path, UInt32(path.count)) > 0 else { throw WorkbenchError.message(L10n.text("当前执行环境未确认，请使用实际主机或容器连接。")) }
        return (String(cString: path) as NSString).lastPathComponent
    }
    private func query(arguments: [String], cancellation: CancellationFlag) throws -> CommandResult {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("SSHWorkbench_OpenSSHBackend.bundle")
        let bundle = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let url = bundle.url(forResource: "agent_sessions", withExtension: "py", subdirectory: "Resources") else { throw WorkbenchError.message(L10n.text("找不到会话读取脚本。")) }
        let script = try String(contentsOf: url, encoding: .utf8)
        let command = (["python3", "-c", script] + arguments).map(RemotePath.quote).joined(separator: " ")
        let result = try runCommand(command, cancellation: cancellation, timeout: 75)
        guard result.status == 0 else { throw WorkbenchError.message(L10n.text("无法读取该设备的会话：需要可用的 Python 3、工具数据权限和有效工作目录；不会安装依赖或修改历史。")) }
        return result
    }
    private func runCommand(_ command: String, cancellation: CancellationFlag, timeout: TimeInterval = 25) throws -> CommandResult {
        let result: CommandResult
        switch target {
        case .local:
            let configuration = try LocalShellConfiguration()
            result = try ProcessRunner.run(executable: configuration.executable, arguments: ["-l", "-c", command], environment: configuration.environment,
                                           cancellation: cancellation, timeout: timeout, outputLimit: 16 * 1024 * 1024, currentDirectory: URL(fileURLWithPath: configuration.directory))
        case .ssh(let host):
            try transport.requirePosixShell(host, cancellation: cancellation)
            result = try ProcessRunner.run(executable: "/usr/bin/ssh", arguments: transport.options(for: host) + [host.address, "\"${SHELL:-/bin/sh}\" -l -c " + RemotePath.quote(command)],
                                           environment: transport.environment(for: host), cancellation: cancellation, timeout: timeout, outputLimit: 16 * 1024 * 1024)
        case .docker(let binding):
            result = try binding.daemon.execute(binding, script: "exec \"${SHELL:-/bin/sh}\" -l -c \"$1\"", arguments: [command], cancellation: cancellation, timeout: timeout, outputLimit: 16 * 1024 * 1024)
        }
        return result
    }
    public func list(history: Bool, tool: CodingAgent? = nil, cancellation: CancellationFlag) throws -> AgentSessionListing {
        let python = try runCommand("if command -v python3 >/dev/null 2>&1; then printf '\\nFARPORT_PYTHON=1\\n'; else printf '\\nFARPORT_PYTHON=0\\n'; fi", cancellation: cancellation).checked()
        if !python.text.split(separator: "\n").contains("FARPORT_PYTHON=1") {
            let output = try runCommand("printf 'FARPORT_HOME\\t%s\\n' \"$HOME\"; printf 'FARPORT_USER\\t'; id -u; for tool in claude codex pi; do printf 'FARPORT_TOOL\\t%s\\t' \"$tool\"; command -v \"$tool\" || printf '\\n'; done", cancellation: cancellation).checked().text
            let rows = output.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            guard let home = rows.first(where: { $0.first == "FARPORT_HOME" && $0.count == 2 })?.last, AgentSessionRecord.validPath(home),
                  let user = rows.first(where: { $0.first == "FARPORT_USER" && $0.count == 2 })?.last else { throw WorkbenchError.message(L10n.text("会话元数据无法识别。")) }
            let tools = CodingAgent.allCases.map { tool in
                let path = rows.first { $0.count == 3 && $0[0] == "FARPORT_TOOL" && $0[1] == tool.rawValue }?.last
                return AgentToolCapability(tool: tool, executable: path.flatMap { AgentSessionRecord.validPath($0) ? $0 : nil })
            }
            return AgentSessionListing(home: home, user: user, tools: tools, sessions: [], notices: ["python3-unavailable"], truncated: false)
        }
        let arguments = (history ? ["--history"] : []) + (tool.map { ["--tool", $0.rawValue] } ?? [])
        let output = try query(arguments: arguments, cancellation: cancellation).text
        guard let line = output.split(separator: "\n").last, let data = String(line).data(using: .utf8) else { throw WorkbenchError.message(L10n.text("会话元数据无法识别。")) }
        let listing = try JSONDecoder().decode(AgentSessionListing.self, from: data)
        guard AgentSessionRecord.validPath(listing.home), listing.sessions.allSatisfy({ tool == nil || $0.tool == tool }) else { throw WorkbenchError.message(L10n.text("会话元数据无法识别。")) }
        for record in listing.sessions { try record.validate() }
        return listing
    }
    public func verify(_ record: AgentSessionRecord, cancellation: CancellationFlag) throws {
        try record.validate()
        let data = try JSONEncoder().encode(record)
        _ = try query(arguments: ["--verify", String(decoding: data, as: UTF8.self)], cancellation: cancellation)
    }
    public func prepare(_ plan: AgentLaunchPlan, cancellation: CancellationFlag = CancellationFlag()) throws -> TerminalProcessLaunch {
        if let record = plan.record { try verify(record, cancellation: cancellation) }
        let ready = "test -d " + RemotePath.quote(plan.directory) + " && test -x " + RemotePath.quote(plan.executable)
        guard try runCommand(ready, cancellation: cancellation).status == 0 else { throw WorkbenchError.message(L10n.text("工具或工作目录已不存在，未启动会话。")) }
        if !plan.isShell, !plan.arguments.isEmpty {
            let arguments = plan.tool == .codex ? [plan.executable, "resume", "--help"] : [plan.executable, "--help"]
            let help = try runCommand(arguments.map(RemotePath.quote).joined(separator: " "), cancellation: cancellation)
            let required = plan.tool == .codex ? "--last" : (plan.tool == .pi && plan.record != nil ? "--session" : "--resume")
            guard help.status == 0, (help.text + help.error).contains(required), plan.tool != .codex || plan.record == nil || (help.text + help.error).contains("--cd") else {
                throw WorkbenchError.message(L10n.text("当前工具版本未确认支持此恢复方式，请使用其原生界面或更新后重试。"))
            }
        }
        let command = plan.command
        switch target {
        case .local:
            let configuration = try LocalShellConfiguration()
            guard FileManager.default.isExecutableFile(atPath: plan.executable), FileManager.default.fileExists(atPath: plan.directory) else {
                throw WorkbenchError.message(L10n.text("工具或工作目录已不存在，未启动会话。"))
            }
            var environment = configuration.environment
            environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
            return TerminalProcessLaunch(executable: configuration.executable, arguments: ["-l", "-c", command], environment: environment, directory: plan.directory)
        case .ssh(let host):
            try transport.requirePosixShell(host, cancellation: cancellation)
            return TerminalProcessLaunch(executable: "/usr/bin/ssh", arguments: try transport.terminalArguments(for: host) + ["\"${SHELL:-/bin/sh}\" -l -c " + RemotePath.quote(command)], environment: transport.environment(for: host))
        case .docker(let binding): return try binding.daemon.agentTerminal(binding, command: command, cancellation: cancellation)
        }
    }
    public func createTmux(_ plan: AgentLaunchPlan, cancellation: CancellationFlag) throws -> String {
        let launch = try prepare(plan, cancellation: cancellation)
        let name = "farport-agent-" + UUID().uuidString.lowercased()
        let command: String
        if case .docker = target {
            var argv = ["/usr/bin/env", "-u", "DOCKER_CONTEXT", "-u", "DOCKER_HOST"]
            if let configuration = launch.environment["DOCKER_CONFIG"] { argv.append("DOCKER_CONFIG=" + configuration) }
            command = (argv + [launch.executable] + launch.arguments).map(RemotePath.quote).joined(separator: " ")
        } else { command = "\"${SHELL:-/bin/sh}\" -l -c " + RemotePath.quote(plan.command) }
        let service = TmuxService(transport: transport, host: target.host)
        try cancellation.check()
        _ = try service.execute("new-session -d -s " + RemotePath.quote(name) + " " + RemotePath.quote(command), cancellation: cancellation).checked()
        return name
    }
}
