import AppKit
import SwiftUI
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum TerminalGraphicsChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let appearance = workspace.store.appearance
        workspace.store.appearance = "dark"
        defer { workspace.store.appearance = appearance }
        let color = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for row in 0..<64 { for column in 0..<64 {
            let offset = row * color.bytesPerRow + column * 4
            color.bitmapData![offset] = 255; color.bitmapData![offset + 1] = 0
            color.bitmapData![offset + 2] = 255; color.bitmapData![offset + 3] = 255
        } }
        let png = color.representation(using: .png, properties: [:])!
        let imageCommand = "\u{1b}_Ga=T,t=d,f=100,i=42,c=8,r=4,q=2;\(png.base64EncodedString())\u{1b}\\"
        let delete = "\u{1b}_Ga=d,d=I,i=42,q=2;\u{1b}\\"
        let terminal = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 400))
        let window = NSWindow(contentRect: terminal.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = terminal; window.orderFront(nil)
        defer { window.orderOut(nil) }
        terminal.nativeBackgroundColor = .black
        terminal.dataReceived(slice: Array(("\u{1b}[?25l\u{1b}[2J\u{1b}[H" + imageCommand).utf8)[...])
        try await Task.sleep(for: .milliseconds(200))
        let rendered = try capture(terminal, output: output.deletingLastPathComponent().appendingPathComponent("kitty.png"))
        guard magentaPixels(rendered) > 500, terminal.displayedGraphicsImages == 1 else { throw WorkbenchError.message("Kitty 图像没有实际渲染") }
        let other = SafeTerminalView(frame: NSRect(x: 720, y: 0, width: 400, height: 400))
        let panes = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 400))
        window.contentView = panes; panes.addSubview(terminal); panes.addSubview(other)
        guard magentaPixels(try capture(other)) == 0 else { throw WorkbenchError.message("图像泄漏到另一个终端分栏") }
        terminal.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        terminal.setFrameSize(NSSize(width: 600, height: 400))
        guard magentaPixels(try capture(terminal)) > 100 else { throw WorkbenchError.message("字号/分栏大小变化丢失图像") }
        terminal.dataReceived(slice: Array(delete.utf8)[...])
        let cleared = try capture(terminal)
        guard magentaPixels(cleared) == 0 else { throw WorkbenchError.message("Kitty 图像删除后残留") }
        terminal.dataReceived(slice: Array(("\u{1b}[?1049h\u{1b}[H" + imageCommand).utf8)[...])
        guard magentaPixels(try capture(terminal)) > 500 else { throw WorkbenchError.message("备用屏幕图片未显示") }
        terminal.dataReceived(slice: Array("\u{1b}[?1049l".utf8)[...])
        guard magentaPixels(try capture(terminal)) == 0 else { throw WorkbenchError.message("离开备用屏幕有图像残留") }
        for _ in 0..<40 { terminal.dataReceived(slice: Array(imageCommand.utf8)[...]); terminal.dataReceived(slice: Array(delete.utf8)[...]) }
        guard magentaPixels(try capture(terminal)) == 0 else { throw WorkbenchError.message("重复动画帧删除后残留") }
        let blocked = "\u{1b}_Ga=T,t=f,f=100,i=43;\(Data("/tmp/farport-no-file.png".utf8).base64EncodedString())\u{1b}\\"
        terminal.dataReceived(slice: Array(blocked.utf8)[...])
        guard terminal.displayedGraphicsImages == 42 else { throw WorkbenchError.message("外部文件图像传输未被阻止") }
        terminal.dataReceived(slice: Array(("\u{1b}[2J\u{1b}[H\u{1b}Pq\"1;1;48;36#0;2;100;0;100#0" + Array(repeating: "!48~", count: 6).joined(separator: "-") + "\u{1b}\\").utf8)[...])
        guard magentaPixels(try capture(terminal)) > 200 else { throw WorkbenchError.message("Sixel 图片未渲染") }
        print("PASS · 原生 Kitty PNG 像素渲染、40轮删除/替换、宿主文件读取阻止")
        var targets: [HostProfile?] = [nil]
        if let host = workspace.store.hosts.first(where: { $0.address == "127.0.0.1" && $0.port == 22281 }) { targets.append(host) }
        for host in targets {
            if let host { workspace.connect(host) } else { workspace.connectLocal() }
            guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("未创建图像测试终端") }
            try await wait { session.connected && session.terminal.window != nil }
            defer { workspace.close(session) }
            session.terminal.send(txt: "printf '\\n%s%s\\n' 'FARPORT_ENV:' \"$TERM_PROGRAM\"\n")
            try await wait { lines(session).contains("FARPORT_ENV:" + TerminalGraphics.program) }
            let before = session.terminal.displayedGraphicsImages
            let encoded = Data(("\u{1b}[2J\u{1b}[H" + imageCommand).utf8).base64EncodedString()
            session.terminal.send(txt: "printf %s \(RemotePath.quote(encoded)) | base64 --decode 2>/dev/null || printf %s \(RemotePath.quote(encoded)) | base64 -D\n")
            try await wait { session.terminal.displayedGraphicsImages > before }
            guard magentaPixels(try capture(session.terminal)) > 500 else { throw WorkbenchError.message("PTY图像字节到达但没有渲染") }
            print("PASS · \(host == nil ? "本机" : "SSH") PTY图像与Farport协议标识，不改TERM/远端配置")
            if let home = ProcessInfo.processInfo.environment[host == nil ? "SWB_QA_CODEX_HOME" : "SWB_QA_REMOTE_CODEX_HOME"],
               let executable = ProcessInfo.processInfo.environment[host == nil ? "SWB_QA_CODEX" : "SWB_QA_REMOTE_CODEX"] {
                session.terminal.dataReceived(slice: Array(delete.utf8)[...])
                session.terminal.send(txt: "clear; export CODEX_HOME=\(RemotePath.quote(home)); \(RemotePath.quote(executable)) --no-daemon --no-alt-screen -C \(RemotePath.quote(home))\n")
                try await wait { lines(session).contains("OpenAI Codex (v") }
                try await Task.sleep(for: .seconds(2))
                let beforePet = session.terminal.displayedGraphicsImages
                session.terminal.send(txt: "/pets rocky")
                try await enter(session)
                do { try await wait { session.terminal.displayedGraphicsImages > beforePet + 2 } }
                catch { try saveText(lines(session), output: output.deletingLastPathComponent().appendingPathComponent(host == nil ? "codex-local.txt" : "codex-ssh.txt")); throw error }
                _ = try capture(session.terminal, output: output.deletingLastPathComponent().appendingPathComponent(host == nil ? "codex-local.png" : "codex-ssh.png"))
                session.terminal.send(txt: "/pets")
                try await enter(session)
                try await Task.sleep(for: .seconds(1))
                guard !lines(session).contains("Pets unavailable") else { throw WorkbenchError.message("Codex宠物选择器仍不可用") }
                _ = try capture(session.terminal, output: output.deletingLastPathComponent().appendingPathComponent(host == nil ? "codex-local-picker.png" : "codex-ssh-picker.png"))
                session.terminal.send(txt: "\u{1b}"); try await Task.sleep(for: .milliseconds(200)); session.terminal.send(txt: "\u{3}\u{3}")
                print("PASS · \(host == nil ? "本机" : "SSH") 真实Codex宠物连续图像帧与选择器")
            }
        }
        if let home = ProcessInfo.processInfo.environment["SWB_QA_REMOTE_CODEX_HOME"], let executable = ProcessInfo.processInfo.environment["SWB_QA_REMOTE_CODEX"], let host = targets.compactMap({ $0 }).first {
            let service = TmuxService(transport: workspace.store.transport, host: host)
            let name = "farport-pet-boundary-" + UUID().uuidString
            try service.create(name: name); defer { try? service.kill(session: name) }
            guard let tmux = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("测试tmux会话不存在") }
            workspace.attachTmux(host, session: tmux)
            guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("未创建tmux终端") }
            defer { workspace.close(session) }
            try await wait { session.connected }
            try await wait { lines(session).contains(host.username + "@") }
            session.terminal.send(txt: "CODEX_HOME=\(RemotePath.quote(home)) \(RemotePath.quote(executable)) --no-daemon --no-alt-screen -C \(RemotePath.quote(home))\n")
            do { try await wait { lines(session).contains("OpenAI Codex (v") } }
            catch { try saveText(lines(session), output: output.deletingLastPathComponent().appendingPathComponent("codex-tmux.txt")); throw error }
            try await Task.sleep(for: .seconds(1))
            session.terminal.send(txt: "/pets"); try await enter(session)
            try await wait { lines(session).contains("Pets are disabled in tmux") }
            guard session.terminal.displayedGraphicsImages == 0 else { throw WorkbenchError.message("错误绕过了Codex的tmux禁用规则") }
            print("PASS · 真实Codex tmux禁用原因被保留，不移除TMUX或修改透传配置")
        }
    }
    private static func enter(_ session: TerminalSession) async throws {
        try await Task.sleep(for: .milliseconds(200))
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: session.terminal.window?.windowNumber ?? 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw WorkbenchError.message("不能构造回车事件") }
        session.terminal.keyDown(with: event)
    }
    static func capture(_ terminal: SafeTerminalView, output: URL? = nil) throws -> NSBitmapImageRep {
        terminal.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(terminal.bounds.width), pixelsHigh: Int(terminal.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw WorkbenchError.message("终端图像无法截图") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.setFillColor(terminal.nativeBackgroundColor.cgColor)
        context.cgContext.fill(terminal.bounds)
        terminal.draw(terminal.bounds)
        NSGraphicsContext.restoreGraphicsState()
        if let output { try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true); try bitmap.representation(using: .png, properties: [:])!.write(to: output) }
        return bitmap
    }
    private static func magentaPixels(_ image: NSBitmapImageRep) -> Int {
        var count = 0
        for row in stride(from: 0, to: image.pixelsHigh, by: 2) { for column in stride(from: 0, to: image.pixelsWide, by: 2) {
            if let color = image.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB), color.redComponent > 0.8, color.greenComponent < 0.2, color.blueComponent > 0.8, color.alphaComponent > 0.8 { count += 1 }
        } }
        return count
    }
    private static func lines(_ session: TerminalSession) -> String {
        let screen = session.terminal.getTerminal()
        return (0..<screen.rows).map { screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "" }.joined(separator: "\n")
    }
    private static func saveText(_ text: String, output: URL) throws { try text.write(to: output, atomically: true, encoding: .utf8) }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("宠物图像验证超时：\(line)") }; try await Task.sleep(for: .milliseconds(100)) }
    }
}
