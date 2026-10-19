import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum ConnectionStabilityChecks {
    static func run(workspace: Workspace) async throws {
        guard let host = workspace.store.hosts.first, host.address == "127.0.0.1", host.name == "Recovery Fixture" else { throw WorkbenchError.message("连接回归仅接受专用隔离SSH目标") }
        let mode = ProcessInfo.processInfo.environment["SWB_QA_RECOVERY_MODE"] ?? "stability"
        if mode == "manual" {
            workspace.connect(host)
            try await wait("SSH测试连接未启动") { workspace.selectedTerminal?.connected == true }
            guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("缺少测试终端") }
            try await assertResponds(session, marker: "RECOVERY_BEFORE")
            let processID = session.terminal.process.shellPid; let connectionID = session.connectionID
            session.reconnect()
            try await wait("运行中手动重连未创建新连接；可能仍在等待被取消的退出通知", timeout: 8) {
                session.connected && session.terminal.process.running && session.terminal.process.shellPid != processID && session.connectionID != connectionID
            }
            try await assertResponds(session, marker: "RECOVERY_AFTER")
            print("PASS · 运行中手动恢复产生新SSH进程且新连接可执行命令")
        } else {
            let service = TmuxService(transport: workspace.store.transport, host: host)
            let name = "recovery-" + String(UUID().uuidString.prefix(8))
            try await Task.detached { try service.create(name: name) }.value
            let job = "printf 'FARPORT_TAB_STABILITY\\n'; sleep 300"
            _ = try await Task.detached { try service.execute("respawn-pane -k -t \(RemotePath.quote(name)) \(RemotePath.quote(job))").checked() }.value
            workspace.connect(host, tmux: name)
            try await wait("tmux测试连接未启动") { workspace.selectedTerminal?.connected == true }
            guard let remote = workspace.selectedTerminal else { throw WorkbenchError.message("缺少tmux终端") }
            try await wait("tmux附着未显示远端任务标记") { hasLine("FARPORT_TAB_STABILITY", session: remote) }
            let target = try await Task.detached { try service.target(session: name) }.value
            let processID = remote.terminal.process.shellPid; let connectionID = remote.connectionID
            workspace.connectLocal()
            try await wait("对照标签未启动") { workspace.selectedTerminal?.isLocal == true && workspace.selectedTerminal?.connected == true }
            guard let local = workspace.selectedTerminal else { throw WorkbenchError.message("缺少对照标签") }
            for iteration in 0..<(mode == "recovery" ? 3 : 70) {
                if iteration < 12 {
                    workspace.selectTerminal(remote); workspace.selectTerminal(local)
                    if iteration % 3 == 0 { workspace.browseFiles(.host(host.id)); workspace.page = .terminal; workspace.selectTerminal(local) }
                }
                try await Task.sleep(for: .seconds(1))
                guard remote.connected, remote.terminal.process.running, remote.terminal.process.shellPid == processID, remote.connectionID == connectionID else {
                    throw WorkbenchError.message("切换或后台等待导致SSH连接改变，秒数：\(iteration + 1)")
                }
                if iteration % 15 == 0 { print("后台标签稳定性：\(iteration + 1)秒，SSH PID与连接代次未变"); fflush(stdout) }
            }
            if mode == "recovery" {
                try await dropSSHConnections(workspace)
                try await wait("异常断线未自动恢复", timeout: 25) { remote.connected && remote.connectionID != connectionID && remote.terminal.process.running }
                guard workspace.selectedTerminalID == local.id else { throw WorkbenchError.message("后台重连抢走了当前标签焦点") }
                let resumed = try await Task.detached { try service.target(session: name) }.value
                guard resumed.processID == target.processID, resumed.command == "sleep" else { throw WorkbenchError.message("重连后tmux任务被重建或结束") }
                let resumedID = remote.connectionID
                remote.pauseAutomaticReconnect()
                try await dropSSHConnections(workspace)
                try await wait("故障注入没有中断SSH", timeout: 10) { !remote.connected }
                remote.recoveryEnvironmentChanged("wake")
                try await Task.sleep(for: .seconds(2))
                guard remote.connectionID == resumedID, remote.retryDeadline == nil else { throw WorkbenchError.message("用户暂停后仍自动恢复") }
                remote.reconnect()
                try await wait("暂停后的手动重连失败") { remote.connected && remote.connectionID != resumedID }
                print("PASS · SSH实际连接被断开后自动恢复原tmux；后台不抢焦点；暂停与手动恢复有效")
                let frozenConnection = remote.connectionID
                let freezeStart = Date()
                try await signalSSHServers(workspace, command: "pkill -STOP -x sshd")
                try await wait("SSH心跳未检测到无响应连接", timeout: 75) { !remote.connected }
                let detectedAfter = Date().timeIntervalSince(freezeStart)
                try await signalSSHServers(workspace, command: "pkill -CONT -x sshd")
                try await wait("SSH恢复响应后未重新附着", timeout: 40) { remote.connected && remote.connectionID != frozenConnection }
                print("PASS · 无TCP断开通知的黑洞故障由SSH心跳检测，约\(Int(detectedAfter))秒；恢复后重新附着")
                try await checkSilentAuthentication(workspace)
                try await checkHostKeyRefusal(workspace, session: remote)
            }
            workspace.selectTerminal(remote)
            let after = try await Task.detached { try service.target(session: name) }.value
            guard after.processID == target.processID, after.command == "sleep" else { throw WorkbenchError.message("后台tmux任务被终止或替换") }
            try await Task.detached { try service.kill(session: name) }.value
            try await wait("正常tmux结束未更新连接状态") { !remote.connected }
            let endedConnection = remote.connectionID
            remote.recoveryEnvironmentChanged("wake")
            try await Task.sleep(for: .seconds(2))
            guard remote.connectionID == endedConnection, remote.retryDeadline == nil else { throw WorkbenchError.message("正常会话结束后仍自动重建") }
            if mode == "stability" { print("PASS · 切标签/文件页与70秒后台无输出等待不重建SSH，远端tmux进程与sleep任务保持") }
        }
        workspace.sessions.forEach { $0.close() }
        try await wait("关闭后SSH子进程未退出") { workspace.sessions.allSatisfy { !$0.terminal.process.running } }
        fflush(stdout)
    }
    private static func assertResponds(_ session: TerminalSession, marker: String) async throws {
        try await Task.sleep(for: .milliseconds(250))
        session.terminal.send(txt: "printf '\\n%s%s\\n' 'FARPORT_' '\(marker)'\n")
        try await wait("SSH终端未返回实际执行结果") {
            hasLine("FARPORT_" + marker, session: session)
        }
    }
    private static func hasLine(_ value: String, session: TerminalSession) -> Bool {
        let terminal = session.terminal.getTerminal()
        return (0..<terminal.rows).contains { terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).trimmingCharacters(in: .whitespacesAndNewlines) == value }
    }
    private static func dropSSHConnections(_ workspace: Workspace) async throws {
        try await signalSSHServers(workspace, command: "pkill -TERM -u tester -x sshd || true")
    }
    private static func signalSSHServers(_ workspace: Workspace, command: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let docker = environment["SWB_QA_DOCKER"], let container = environment["SWB_QA_CONTAINER_ID"], container.count == 64,
              container.allSatisfy({ $0.isHexDigit }) else { throw WorkbenchError.message("缺少本轮独占容器标识，拒绝故障注入") }
        let expected = workspace.store.paths.root.lastPathComponent
        try await Task.detached {
            let label = try ProcessRunner.run(executable: docker, arguments: ["inspect", "-f", "{{index .Config.Labels \"local.sshworkbench.recovery\"}}", container]).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label == expected else { throw WorkbenchError.message("容器归属不符，拒绝中断连接") }
            _ = try ProcessRunner.run(executable: docker, arguments: ["exec", container, "sh", "-c", command]).checked()
        }.value
    }
    private static func checkSilentAuthentication(_ workspace: Workspace) async throws {
        guard let helper = workspace.store.transport.askpass else { throw WorkbenchError.message("缺少凭据助手") }
        var environment = ProcessInfo.processInfo.environment
        environment["SWB_SILENT_AUTH"] = "1"; environment["SWB_CREDENTIAL_ACCOUNT"] = "recovery-check-" + UUID().uuidString
        for prompt in ["Password:", "Are you sure you want to continue connecting (yes/no)?"] {
            let result = try await Task.detached { try ProcessRunner.run(executable: helper, arguments: [prompt], environment: environment, timeout: 8) }.value
            guard result.status == 1, result.output.isEmpty else { throw WorkbenchError.message("自动恢复缺少凭据时没有安静失败") }
        }
        print("PASS · 无缓存凭据与新指纹提示均静默拒绝，不打开密码或信任窗口")
    }
    private static func checkHostKeyRefusal(_ workspace: Workspace, session: TerminalSession) async throws {
        guard let host = session.host else { return }
        let paths = workspace.store.paths
        let original = try Data(contentsOf: paths.knownHosts)
        defer { try? original.write(to: paths.knownHosts, options: .atomic) }
        let key = paths.root.appendingPathComponent("different-host-key")
        _ = try await Task.detached { try ProcessRunner.run(executable: "/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key.path]).checked() }.value
        let publicKey = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        try Data("[127.0.0.1]:\(host.port) \(publicKey)\n".utf8).write(to: paths.knownHosts, options: .atomic)
        try await dropSSHConnections(workspace)
        try await wait("指纹不匹配时没有暂停自动恢复", timeout: 25) { session.autoReconnectPaused && !session.connected }
        let paused = session.connectionID
        try await Task.sleep(for: .seconds(2))
        guard session.connectionID == paused, session.retryDeadline == nil else { throw WorkbenchError.message("指纹变化后仍重试或自动接受") }
        try original.write(to: paths.knownHosts, options: .atomic)
        session.reconnect()
        try await wait("恢复测试指纹后手动连接失败") { session.connected && session.connectionID != paused }
        print("PASS · 指纹不匹配暂停且不自动接受，恢复原可信记录后手动连接有效")
    }
    private static func wait(_ failure: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() { if Date() >= deadline { throw WorkbenchError.message(failure) }; try await Task.sleep(for: .milliseconds(50)) }
    }
}
