import Foundation
import Darwin
import WorkbenchCore
import OpenSSHBackend

func checkLocalTmuxDirectory() throws {
    func resolved(_ path: String?) -> String? {
        guard let path, let buffer = realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("farport-tmux-directory-" + UUID().uuidString)
    let paths = try ApplicationPaths(root: root)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: paths.sockets) }
    let executable = try TmuxService.localExecutable()
    let socket = "farport-directory-" + UUID().uuidString
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let service = TmuxService(transport: transport, host: nil, socketName: socket)
    defer { _ = try? ProcessRunner.run(executable: executable, arguments: ["-L", socket, "kill-server"]) }
    _ = try ProcessRunner.run(executable: executable, arguments: ["-L", socket, "-f", "/dev/null", "new-session", "-d", "-s", "fixture", "-c", root.path, "/bin/sleep 120"]).checked()
    _ = try service.execute("set-option -g default-shell /bin/sh").checked()
    _ = try service.execute("set-option -g default-command 'exec /bin/sh'").checked()
    try service.create(name: "home-check")
    let session = try service.sessions().first { $0.name == "home-check" }
    let pane = try service.panes().first { $0.sessionID == session?.id }
    guard let pane else { throw WorkbenchError.message("没有创建本机tmux测试窗格") }
    let expected = resolved(FileManager.default.homeDirectoryForCurrentUser.path)!
    let actual = resolved(pane.directory)!
    print("CHECK · 应用cwd=\(FileManager.default.currentDirectoryPath)，新建本机tmux cwd=\(actual)，期望=\(expected)")
    try expect(actual == expected, "本机tmux新会话必须从主目录启动，而不是继承应用工作目录")
    let previousDirectory = try service.panes().first { $0.sessionID != session?.id }?.directory
    try expect(resolved(previousDirectory) == resolved(root.path), "创建新会话不改变旧窗格的工作目录")
    let project = root.appendingPathComponent("project 空格 ' dollar$;目录")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    _ = try service.execute("send-keys -l -t \(RemotePath.quote(pane.id)) \(RemotePath.quote("cd " + RemotePath.quote(project.path)))").checked()
    _ = try service.execute("send-keys -t \(RemotePath.quote(pane.id)) Enter").checked()
    let deadline = Date().addingTimeInterval(5)
    while try resolved(service.panes().first(where: { $0.id == pane.id })?.directory) != resolved(project.path) {
        guard Date() < deadline else { throw WorkbenchError.message("测试窗格没有进入项目目录") }
        Thread.sleep(forTimeInterval: 0.05)
    }
    try service.createWindow(session: session!.id)
    let windowPane = try service.panes().first { $0.sessionID == session?.id && $0.id != pane.id }
    try expect(resolved(windowPane?.directory) == resolved(project.path), "本机tmux新窗口应继承目标窗格目录，不回到应用工作目录")
    try service.split(pane: pane.id)
    let splitPane = try service.panes().first { $0.windowID == pane.windowID && $0.id != pane.id }
    try expect(resolved(splitPane?.directory) == resolved(project.path), "本机tmux分割应继承被分割窗格目录")
    try expect(try resolved(service.panes().first { $0.id == pane.id }?.directory) == resolved(project.path), "新建窗口与分割不改变原窗格目录")
    try service.create(name: "second-home-check")
    let secondSession = try service.sessions().first { $0.name == "second-home-check" }
    try expect(try resolved(service.panes().first { $0.sessionID == secondSession?.id }?.directory) == expected, "有项目窗格时新会话仍从主目录启动")
    try expect(FileManager.default.currentDirectoryPath != expected, "回归必须从非主目录运行")
    print("PASS · 本机tmux新会话从主目录启动，新窗口/分割继承目标目录，已有窗格不变")
}
