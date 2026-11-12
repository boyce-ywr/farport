import Foundation
import WorkbenchCore
import OpenSSHBackend

/// 离线断言：解析真实输出样本、名称校验、旧配置兼容与环境隔离。
func checkMultiplexers() throws {
    let zellij = MultiplexerParsing.zellijSessions("work [Created 2s ago] \n\u{1B}[32;1mold\u{1B}[m [Created 3h ago] (EXITED - attach to resurrect)\nme [Created 1m ago] (current)\nNo active zellij sessions found.\n")
    try expect(zellij.map(\.name) == ["work", "old", "me"] && zellij.map(\.running) == [true, false, true], "Zellij 会话列表解析名称、退出状态与颜色")
    let panes = MultiplexerParsing.zellijPanes("""
    [{"id":0,"is_plugin":true,"exited":false,"tab_name":"Tab #1"},
     {"id":0,"is_plugin":false,"is_focused":true,"exited":false,"tab_name":"Tab #1","pane_command":"/bin/zsh","pane_cwd":"/private/tmp","unknown":[1]},
     {"id":2,"is_plugin":false,"exited":true,"tab_name":"Tab #1"}]
    """, session: "work")
    try expect(panes.count == 1 && panes[0].id == "terminal_0" && panes[0].command == "zsh" && panes[0].directory == "/private/tmp" && panes[0].focused, "Zellij 窗格过滤插件与已退出窗格")
    let herdr = MultiplexerParsing.herdrSessions(#"{"sessions":[{"default":true,"name":"default","running":true},{"name":"bad name","running":true},{"name":"x","running":false}]}"#)
    try expect(herdr.map(\.name) == ["default", "x"] && herdr.map(\.running) == [true, false], "herdr 会话列表解析运行状态并忽略非法名称")
    let herdrPanes = MultiplexerParsing.herdrPanes(workspaces: #"{"result":{"workspaces":[{"workspace_id":"w1","label":"proj"}]}}"#,
        panes: #"{"result":{"panes":[{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t3","cwd":"/a","foreground_cwd":"/b","focused":true,"agent":"claude","agent_status":"working","terminal_title_stripped":"Claude Code"}]}}"#, session: "default")
    try expect(herdrPanes?.first.map { $0.group == "proj · t3" && $0.directory == "/b" && $0.agent == "claude" && $0.agentStatus == "working" } == true, "herdr 窗格解析工作区、目录与 Agent 状态")
    try expect(MultiplexerParsing.herdrPanes(workspaces: "", panes: #"{"id":"x","error":{"code":"server_not_running"}}"#, session: "s") == nil, "herdr 服务未运行不当作空窗格")
    try expect(MultiplexerKind.parseVersion("zellij 0.45.1")! == (0, 45) && MultiplexerKind.parseVersion("herdr 0.9.5")! == (0, 9) && MultiplexerKind.parseVersion("tmux 3.4a")! == (3, 4), "版本解析")
    try expect(!MultiplexerKind.zellij.supports(version: (0, 43)) && MultiplexerKind.zellij.supports(version: (0, 44)) && MultiplexerKind.herdr.supports(version: (1, 0)), "最低版本判断")
    for name in ["", "a b", "a;b", "-x", ".x", "a/b", "中文", String(repeating: "a", count: 65)] {
        try rejects("会话名称 \(name)") { try MultiplexerKind.herdr.validateSessionName(name) }
    }
    try MultiplexerKind.zellij.validateSessionName("farport-test_1.a")
    let old = try JSONDecoder().decode(HostProfile.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"h","address":"a","port":22,"username":"","group":"g","identityFile":"","jumpHost":"","prefersTmux":true,"lastSession":"","color":"mint"}"#.utf8))
    try expect(old.entryMultiplexer == .tmux, "旧配置 prefersTmux=true 视为 tmux")
    var host = old; host.entryMultiplexer = .herdr
    let decoded = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(host))
    try expect(decoded.entryMultiplexer == .herdr && !decoded.prefersTmux, "选择 herdr 后旧字段为 false，旧版本按普通终端连接")
    host.entryMultiplexer = nil
    try expect(host.entryMultiplexer == nil && !host.prefersTmux, "选择普通终端清除偏好")
    let saved = try JSONDecoder().decode(SavedTerminal.self, from: Data(#"{"id":"\#(UUID().uuidString)","tmuxID":"$1"}"#.utf8))
    try expect(saved.multiplexer == nil && saved.tmuxID == "$1", "旧工作区快照可解码")
    try expect(SavedTerminal(id: UUID(), hostID: nil, connectionKey: nil, tmuxID: nil, multiplexer: MultiplexerAttachment(kind: .herdr, session: "x", create: true)).multiplexer?.create == false, "工作区恢复只附着，不新建")
    let script = MultiplexerService.attachScript(MultiplexerAttachment(kind: .zellij, session: "it's"))
    try expect(script.contains("attach 'it'\"'\"'s'") && script.contains("exit 127"), "附着命令引用会话名并在缺少工具时退出 127")
    try expect(MultiplexerService.attachScript(MultiplexerAttachment(kind: .herdr, session: "w", create: true)).contains("--session 'w'"), "herdr 新建经 --session 在终端中创建")
    let environment = MultiplexerService.isolatedEnvironment(["TMUX": "1", "TMUX_PANE": "%1", "ZELLIJ": "0", "ZELLIJ_SESSION_NAME": "s", "HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p1", "PATH": "/bin", "HERDR": "keep"])
    try expect(environment == ["PATH": "/bin", "HERDR": "keep"], "本机终端清除外层多路复用器环境变量")
    print("PASS · Zellij/herdr 解析、名称校验、配置兼容与环境隔离")
}

/// 实测本机 Zellij 与 herdr：只使用随机的 farport-test-* 会话，结束后清理，不触碰其他会话。
func checkMultiplexersLive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farport-mux-" + UUID().uuidString)
    let paths = try ApplicationPaths(root: root)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: paths.sockets) }
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let suffix = String(UUID().uuidString.prefix(8)).lowercased()

    let zellij = MultiplexerService(kind: .zellij, transport: transport, host: nil)
    guard case .available(let zellijVersion) = try zellij.availability() else { throw WorkbenchError.message("本机未安装可用的 Zellij") }
    let name = "farport-test-z" + suffix, renamed = name + "-r"
    defer { _ = try? zellij.kill(session: MultiplexerSession(kind: .zellij, name: name, running: true)); _ = try? zellij.kill(session: MultiplexerSession(kind: .zellij, name: renamed, running: true)) }
    let created = try zellij.createDetached(name: name)
    try rejects("Zellij 重复名称") { _ = try zellij.createDetached(name: name) }
    var zellijPanes: [MultiplexerPane] = []
    let deadline = Date().addingTimeInterval(10)
    while zellijPanes.isEmpty, Date() < deadline { zellijPanes = try zellij.panes(of: [created]); if zellijPanes.isEmpty { Thread.sleep(forTimeInterval: 0.3) } }
    try expect(!zellijPanes.isEmpty && zellijPanes.allSatisfy { $0.session == name && !$0.directory.isEmpty }, "Zellij 后台会话可读取窗格与目录")
    try zellij.rename(session: name, to: renamed)
    try expect(try zellij.sessions().contains { $0.name == renamed && $0.running } && !(try zellij.sessions().contains { $0.name == name }), "Zellij 重命名生效")
    try zellij.kill(session: MultiplexerSession(kind: .zellij, name: renamed, running: true))
    try expect(!(try zellij.sessions().contains { $0.name == renamed }), "Zellij 结束会话后不留下 EXITED 记录")
    print("PASS · 本机 \(zellijVersion)：后台新建、重复名称拒绝、窗格、重命名与结束删除")

    let herdr = MultiplexerService(kind: .herdr, transport: transport, host: nil)
    guard case .available(let herdrVersion) = try herdr.availability() else { throw WorkbenchError.message("本机未安装可用的 herdr") }
    let herdrName = "farport-test-h" + suffix
    let configuration = try LocalShellConfiguration()
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/bin/sh")
    server.arguments = ["-c", MultiplexerService.script(.herdr, "exec \(MultiplexerService.executableReference) --session '\(herdrName)' server")]
    server.environment = MultiplexerService.isolatedEnvironment(configuration.environment)
    server.standardInput = FileHandle.nullDevice; server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate() }; _ = try? herdr.kill(session: MultiplexerSession(kind: .herdr, name: herdrName, running: true)) }
    var session: MultiplexerSession?
    let herdrDeadline = Date().addingTimeInterval(10)
    while session == nil, Date() < herdrDeadline { session = try herdr.sessions().first { $0.name == herdrName && $0.running }; if session == nil { Thread.sleep(forTimeInterval: 0.3) } }
    guard let session else { throw WorkbenchError.message("herdr 测试会话未启动") }
    _ = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", MultiplexerService.script(.herdr, "\(MultiplexerService.executableReference) --session '\(herdrName)' workspace create --cwd /tmp --label fixture --no-focus")],
                              environment: MultiplexerService.isolatedEnvironment(configuration.environment)).checked()
    let herdrPanes = try herdr.panes(of: [session])
    try expect(herdrPanes.count == 1 && herdrPanes[0].group.hasPrefix("fixture") && herdrPanes[0].directory.hasSuffix("/tmp"), "herdr 读取工作区标签、窗格与目录")
    try rejects("herdr 重命名") { try herdr.rename(session: herdrName, to: herdrName + "-r") }
    try herdr.kill(session: session)
    try expect(!(try herdr.sessions().contains { $0.name == herdrName }), "herdr 结束会话后删除记录")
    print("PASS · 本机 \(herdrVersion)：会话与窗格读取、重命名禁用、结束并删除")
}
