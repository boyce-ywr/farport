import AppKit
import Foundation
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum ReadmeScreenshots {
    nonisolated static let directory = "/home/tester/farport-demo"
    nonisolated static let markdown = """
    # 项目交接笔记

    这里记录 **Atlas 开发机** 的日常工作。截图使用演示数据，不连接生产环境。

    ## 开始工作

    1. 连接主机，进入 tmux 会话
    2. 查看项目文件和运行日志
    3. 将交付文件复制到 Orbit 测试机

    ## 文件说明

    - `README.md`：项目说明与交接记录
    - `report.html`：可在浏览器查看的演示报告
    - `logs/`：日志目录

    > 关闭终端标签不会结束已附着的 tmux 会话。

    ```bash
    cd ~/farport-demo
    tmux list-sessions
    ```

    ## 交接前检查

    - 确认目标主机和保存目录
    - 同名文件先检查，再决定是否覆盖
    - 保存笔记，保留工作现场
    """
    static func run(workspace: Workspace, scene: String, output: URL) async throws {
        let store = workspace.store
        guard store.isTestWorkspace, store.hosts.count == 2,
              store.hosts.allSatisfy({ $0.address == "127.0.0.1" && [22281, 22282].contains($0.port) && $0.username == "tester" }),
              ["terminal", "tmux", "markdown", "html", "transfers"].contains(scene) else { throw WorkbenchError.message("介绍截图仅使用隔离演示主机。") }
        let first = store.hosts[0]; let second = store.hosts[1]; let transport = store.transport
        store.appearance = "dark"; store.fontSize = 14; workspace.sidebarCollapsed = false
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { throw WorkbenchError.message("没有可截图的工作台窗口。") }
        window.setContentSize(NSSize(width: 1360, height: 860))
        try await Task.detached {
            let client = try transport.files(first); defer { client.close() }
            let html = """
            <!doctype html><html lang="zh"><meta charset="utf-8"><title>项目交付报告</title>
            <style>body{font:16px -apple-system,sans-serif;color:#213b44;background:#f5f9fa;padding:32px;margin:0}small{color:#53747d;letter-spacing:2px}h1{font-size:30px;margin-top:30px}p,li{line-height:1.9}section{background:#fff;border:1px solid #d9e5e7;border-radius:12px;padding:24px;margin:24px 0}a{color:#007e87}code{color:#08767a}</style>
            <small>FARPORT / DEMO REPORT</small><h1>项目交付报告</h1><p>在文件列表中选中 HTML，即可查看页面。<br>也可以在浏览器打开，保留相对链接与锚点。</p>
            <section><h2>本次交接</h2><ul><li>项目说明：<code>README.md</code></li><li>运行日志：<code>logs/application.log</code></li><li>交付目标：Orbit 测试机</li></ul></section>
            <a href="#notes">查看交接备注 ↓</a><h2 id="notes">备注</h2><p>这是用于产品截图的演示报告。<br>文件从隔离 SSH 主机按需读取；不需要在远端部署 Web 服务。</p></html>
            """
            for folder in [directory, directory + "/logs", directory + "/exports"] {
                do { try client.mkdir(folder) } catch { guard try client.stat(folder).isDirectory else { throw error } }
            }
            for (name, text) in [("README.md", markdown), ("report.html", html), ("logs/application.log", "[demo] connection ready\n[demo] files loaded\n[demo] workspace saved\n"), ("exports/handoff.txt", "Farport demo handoff\n"), ("settings.json", "{\n  \"environment\": \"demo\",\n  \"project\": \"farport-demo\"\n}\n")] {
                let path = directory + "/" + name
                do { try client.createFile(path) } catch { guard try client.stat(path).isRegularFile else { throw error } }
                let existing = try client.preview(path)
                try client.saveText(path, data: Data(text.utf8), expected: client.stat(path), original: existing)
            }
        }.value
        if scene == "terminal" {
            workspace.connect(first)
            guard let left = workspace.selectedTerminal else { throw WorkbenchError.message("无法创建演示终端。") }
            workspace.connect(second, split: true)
            guard let right = workspace.selectedTerminal else { throw WorkbenchError.message("无法创建演示分栏。") }
            try await wait { left.connected && right.connected }
            left.terminal.send(txt: "export PS1='tester@atlas:~/farport-demo$ '; cd ~/farport-demo; clear; printf '\\033[1;36mAtlas · 开发机\\033[0m\\n\\n'; printf '$ pwd\\n'; pwd; printf '\\n$ ls -1\\n'; ls -1; printf '\\n$ cat logs/application.log\\n'; cat logs/application.log\n")
            right.terminal.send(txt: "export PS1='tester@orbit:~$ '; clear; printf '\\033[1;36mOrbit · 测试机\\033[0m\\n\\n'; printf '$ whoami\\n'; whoami; printf '\\n$ uname -sm\\n'; uname -sm; printf '\\n$ df -h /\\n'; df -h /; printf '\\n同一标签内分别操作两台 SSH 主机。\\n'\n")
            workspace.selectTerminal(left)
        } else if scene == "tmux" {
            try await Task.detached {
                let service = TmuxService(transport: transport, host: first)
                let names = ["demo-development", "demo-logs", "demo-release"]
                for name in names {
                    let exists = try service.execute("has-session -t \(RemotePath.quote(name))").status == 0
                    if !exists { try service.create(name: name) }
                }
                for (name, title) in zip(names, ["editor", "logs", "release"]) {
                    _ = try service.execute("rename-window -t \(RemotePath.quote(name)) \(RemotePath.quote(title))").checked()
                    _ = try service.execute("send-keys -t \(RemotePath.quote(name)) \(RemotePath.quote("cd " + directory + "; clear")) Enter").checked()
                }
            }.value
            workspace.page = .tmux
        } else if scene == "transfers" {
            let target = "/home/tester/farport-demo-incoming"
            try await Task.detached {
                let client = try transport.files(second); defer { client.close() }
                do { try client.mkdir(target) } catch { guard try client.stat(target).isDirectory else { throw error } }
            }.value
            let incoming = target + "/" + UUID().uuidString.lowercased()
            let job = TransferJob(source: FileEndpoint(hostID: first.id, path: directory + "/exports"), destination: FileEndpoint(hostID: second.id, path: incoming))
            store.queue(job)
            try await wait { store.transfers.first(where: { $0.id == job.id })?.status == .completed }
            let collision = TransferJob(source: FileEndpoint(hostID: first.id, path: directory + "/exports/handoff.txt"), destination: FileEndpoint(hostID: second.id, path: incoming + "/handoff.txt"))
            store.queue(collision)
            try await wait { store.pendingConflict?.id == collision.id }
            workspace.page = .transfers
        } else {
            workspace.browseFiles(.host(first.id))
            guard let browser = workspace.currentFileBrowser else { throw WorkbenchError.message("文件浏览器不可用。") }
            try await wait { !browser.busy }
            browser.load(directory)
            try await wait { !browser.busy && browser.path == directory }
            let name = scene == "html" ? "report.html" : "README.md"
            guard let file = browser.files.first(where: { $0.name == name }) else { throw WorkbenchError.message("缺少演示文件。") }
            browser.selection = [file.path]; browser.preview(file)
            try await wait { !browser.previewBusy && (scene != "html" || browser.webURL != nil) }
            browser.previewRatio = 0.52
        }
        try await Task.sleep(for: .seconds(3))
        window.displayIfNeeded()
        guard let view = window.contentView?.superview, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw WorkbenchError.message("无法捕获原生工作台视图。") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
            context.saveGState()
            context.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width, y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            context.setBlendMode(.destinationOver)
            for session in workspace.sessions where session.terminal.window === window {
                context.setFillColor(session.terminal.nativeBackgroundColor.cgColor)
                context.fill(session.terminal.convert(session.terminal.bounds, to: view))
            }
            context.restoreGState()
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        workspace.sessions.forEach { $0.close() }
        print("PASS · README 原生演示截图：\(scene)")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("演示场景准备超时。") }; try await Task.sleep(for: .milliseconds(100)) }
    }
}
