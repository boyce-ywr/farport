import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkRemoteTmuxPath(root: URL) throws {
    let paths = try ApplicationPaths(root: root)
    let hosts = try paths.load([HostProfile].self, from: paths.hosts)
    guard let host = hosts.first, hosts.count == 1, host.address == "127.0.0.1", host.port == 22283 else { throw WorkbenchError.message("只允许专用 tmux PATH 隔离节点") }
    let transport = SSHTransport(paths: paths, noninteractive: true)
    try verify(transport.run(host, command: "tmux -V").status != 0, "测试环境未复现非交互 PATH 缺失")
    try verify(transport.run(host, command: "/opt/homebrew/bin/tmux -V").status == 0, "测试 tmux 未安装")
    let name = "path-" + UUID().uuidString
    _ = try transport.run(host, command: "/opt/homebrew/bin/tmux new-session -d -s \(RemotePath.quote(name))").checked()
    defer { _ = try? transport.run(host, command: "/opt/homebrew/bin/tmux kill-session -t \(RemotePath.quote(name))") }
    let service = TmuxService(transport: transport, host: host)
    guard let session = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("非交互 PATH 不含 Homebrew 时仍未检测到既有会话") }
    print("PASS · 精简远端 PATH 下读取既有 Homebrew tmux 会话")
    try service.createWindow(session: session.id)
    guard let pane = try service.panes().first(where: { $0.sessionID == session.id }) else { throw WorkbenchError.message("未读取 tmux 窗格") }
    try service.split(pane: pane.id)
    try service.rename(session: session.id, name: name + "-renamed")
    try verify(service.sessions().contains { $0.name == name + "-renamed" }, "改名失败")
    let detached = DispatchGroup(); detached.enter()
    DispatchQueue.global().async {
        defer { detached.leave() }
        for _ in 0..<30 {
            if let current = try? transport.run(host, command: "/opt/homebrew/bin/tmux display-message -p -t \(RemotePath.quote(session.id)) '#{session_attached}'"), current.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                _ = try? transport.run(host, command: "/opt/homebrew/bin/tmux detach-client -s \(RemotePath.quote(session.id))")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    let attach = try ProcessRunner.run(executable: "/usr/bin/ssh", arguments: transport.terminalArguments(for: host, tmuxSession: session.id), environment: transport.environment(for: host), timeout: 8)
    _ = detached.wait(timeout: .now() + 2)
    try verify(attach.status == 0, "终端附着仍失败：\(attach.error)")
    print("PASS · 同一路径解析用于管理、窗口、分割、改名及真实 PTY 附着")
}
