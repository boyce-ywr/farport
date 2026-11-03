import AppKit
import IOSurface
import WorkbenchCore
import OpenSSHBackend
import RemoteDesktop

/// 内嵌远程桌面界面回归：真实 Farport 视图连接 TigerVNC 夹具（scripts/check-remote-desktop.sh --ui 启动）。
@MainActor
enum RemoteDesktopChecks {
    /// 图层当前显示的 IOSurface 与帧缓冲逐像素一致（验证真正显示出来，而不只是数据到达）。
    private static func displayedMatches(_ session: RemoteDesktopSession) -> Bool {
        guard let client = session.client, client.statistics.frames >= 1, let shown = session.view.displayedSnapshot() else { return false }
        let frame = client.framebuffer.snapshot().pixels
        return shown.count == frame.count && zip(shown, frame).allSatisfy { ($0 & 0xFFFFFF) == ($1 & 0xFFFFFF) }
    }
    static func run(workspace: Workspace) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let docker = environment["SWB_QA_DOCKER"], let container = environment["SWB_QA_VNC_CONTAINER"], let password = environment["SWB_QA_VNC_PASSWORD"],
              let fixture = workspace.store.hosts.first(where: { $0.address == "127.0.0.1" && $0.port == 22290 }) else { throw WorkbenchError.message("需要远程桌面夹具与 127.0.0.1:22290 测试主机") }
        func shell(_ command: String) throws -> String {
            try ProcessRunner.run(executable: docker, arguments: ["exec", "-u", "tester", container, "sh", "-c", command], timeout: 15).checked().text
        }
        func wait(_ what: String, timeout: TimeInterval = 20, _ condition: () throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while try !condition() {
                guard Date() < deadline else { throw WorkbenchError.message("远程桌面界面回归超时：\(what)") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let board = NSPasteboard.general
        let previousClipboard = board.string(forType: .string)
        let endpoint = try ScreenSharingEndpoint(host: "127.0.0.1", port: 25902)
        RemoteDesktopCredentialStore.delete(host: fixture.id, endpoint: endpoint, username: "")
        defer {
            RemoteDesktopCredentialStore.deleteAll(host: fixture.id)
            board.clearContents(); if let previousClipboard { board.setString(previousClipboard, forType: .string) }
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { throw WorkbenchError.message("没有主窗口") }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)

        // 1. 直连：登录框输入口令并保存到钥匙串
        workspace.openDesktop(host: fixture, endpoint: endpoint, throughSSH: false)
        guard let desktop = workspace.desktops.last else { throw WorkbenchError.message("未创建桌面会话") }
        try await wait("口令登录框") { desktop.phase == .credentials(.password) || { if case .failed = desktop.phase { return true }; return false }() }
        guard desktop.phase == .credentials(.password) else { throw WorkbenchError.message("未出现口令登录框：\(desktop.phase)") }
        desktop.submitCredentials(username: "", password: password, save: true)
        try await wait("连接远程桌面") { desktop.phase == .connected }
        try await wait("画面显示在图层中且与帧缓冲一致") { displayedMatches(desktop) }
        guard workspace.selectedDesktopID == desktop.id, desktop.view.window === window, desktop.view.bounds.width > 100, desktop.info?.isMacOS == false, desktop.commandMapping == .control else { throw WorkbenchError.message("桌面标签、视图显示或远端类型判断不正确") }
        guard RemoteDesktopCredentialStore.load(host: fixture.id, endpoint: endpoint, username: "") == password else { throw WorkbenchError.message("勾选保存后钥匙串没有口令") }
        print("PASS · 内嵌桌面标签直连、登录框口令认证并保存到 Farport 钥匙串、显示图层与帧缓冲一致、Linux 远端自动采用 ⌘→Ctrl")

        // 2. 键盘：普通输入与被拦截的 ⌘ 快捷键（映射为 Ctrl，不触发 Farport 菜单）
        try await wait("桌面视图获得焦点") { window.makeFirstResponder(desktop.view); return desktop.view.hasKeyboardFocus }
        _ = try shell(": > /tmp/keys.txt")
        func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
                if type == .keyDown, flags.contains(.command) { _ = desktop.view.performKeyEquivalent(with: event) } else if type == .keyDown { desktop.view.keyDown(with: event) } else { desktop.view.keyUp(with: event) }
            }
        }
        func modifier(_ code: UInt16, _ flags: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            desktop.view.flagsChanged(with: event)
        }
        for (character, code) in [("f", UInt16(3)), ("a", 0), ("r", 15), ("p", 35)] { key(character, code: code) }
        modifier(55, .command); key("l", code: 37, flags: .command); modifier(55, [])
        key("\r", code: 36)
        do { try await wait("按键到达远端 xterm") { (try? shell("od -An -c /tmp/keys.txt | tr -s ' '")) == " f a r p \\f \\n\n" } }
        catch { throw WorkbenchError.message(error.localizedDescription + "，实际：" + ((try? shell("od -An -c /tmp/keys.txt")) ?? "?") + "，xterm 焦点：" + ((try? shell("DISPLAY=:2 xdotool getwindowfocus getwindowname")) ?? "?")) }
        guard NSApp.isRunning, workspace.desktops.contains(where: { $0 === desktop }) else { throw WorkbenchError.message("⌘ 快捷键被 Farport 菜单处理") }
        print("PASS · 键盘直达远端；⌘L 被桌面拦截并映射为 Ctrl+L，未触发 Farport 菜单")

        // 3. 指针：视图坐标经等比缩放映射到远端像素
        let rect = desktop.view.fitRect
        let target = NSPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY - rect.height * 0.5)
        let moved = NSEvent.mouseEvent(with: .mouseMoved, location: desktop.view.convert(target, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        desktop.view.mouseMoved(with: moved)
        try await wait("指针到达远端") {
            guard let text = try? shell("DISPLAY=:2 xdotool getmouselocation"), let x = Int(text.split(separator: " ")[0].dropFirst(2)), let y = Int(text.split(separator: " ")[1].dropFirst(2)) else { return false }
            return abs(x - 256) <= 2 && abs(y - 384) <= 2
        }
        print("PASS · 指针按适应缩放映射到远端 1024×768 坐标")

        // 4. 剪贴板：获得焦点时本地 → 远端；远端变化在焦点期间写回本地
        let outgoing = "Farport 内嵌桌面剪贴板 \(Int.random(in: 1000...9999))"
        window.makeFirstResponder(nil)
        board.clearContents(); board.setString(outgoing, forType: .string)
        window.makeFirstResponder(desktop.view)
        try await wait("本地文本同步到远端") { (try? shell("DISPLAY=:2 xclip -o -selection clipboard")) == outgoing }
        let incoming = "远端剪贴板写回 \(Int.random(in: 1000...9999))"
        _ = try shell("printf %s '\(incoming)' | DISPLAY=:2 xclip -i -selection clipboard")
        try await wait("远端文本写回本地") { board.string(forType: .string) == incoming }
        guard desktop.utf8Clipboard else { throw WorkbenchError.message("未启用扩展剪贴板") }
        print("PASS · 桌面获得焦点时中文剪贴板双向同步（扩展剪贴板 UTF-8）")

        // 5. 弹出为独立窗口再收回，连接保持
        RemoteDesktopWindows.shared.show(desktop)
        try await wait("弹出窗口") { desktop.poppedOut && desktop.view.window !== window && desktop.view.window != nil }
        let frames = desktop.client?.statistics.frames ?? 0
        _ = try shell("DISPLAY=:2 xdotool type --delay 1 ab && DISPLAY=:2 xdotool key ctrl+u")
        try await wait("独立窗口继续收到画面") { (desktop.client?.statistics.frames ?? 0) > frames }
        RemoteDesktopWindows.shared.dock(desktop)
        try await wait("收回到标签") { !desktop.poppedOut && desktop.view.window === window && desktop.phase == .connected }
        print("PASS · 弹出为独立窗口与收回标签，连接不中断")

        // 6. 重新连接使用钥匙串自动登录；错误口令被拒绝后不自动重试并删除已保存口令
        desktop.connect()
        try await wait("钥匙串自动登录") { desktop.phase == .connected }
        RemoteDesktopCredentialStore.save("wrongpass", host: fixture.id, endpoint: endpoint, username: "")
        desktop.connect()
        try await wait("错误口令结果") { if case .failed = desktop.phase { return true }; return false }
        guard desktop.credentialError != nil, RemoteDesktopCredentialStore.load(host: fixture.id, endpoint: endpoint, username: "") == nil else { throw WorkbenchError.message("错误口令未清除或未提示") }
        desktop.connect()
        try await wait("失败后重新询问口令") { desktop.phase == .credentials(.password) }
        desktop.cancelCredentials()
        try await wait("取消后关闭标签") { !workspace.desktops.contains(where: { $0 === desktop }) }
        print("PASS · 钥匙串自动登录；错误口令被拒绝后清除已保存口令、重新询问而不自动重试；取消即关闭")

        // 7. 经 SSH -W 打开（RFB 跑在 ssh 子进程上）
        workspace.openDesktop(host: fixture, endpoint: try ScreenSharingEndpoint(host: "127.0.0.1", port: 5902), throughSSH: true)
        guard let tunneled = workspace.desktops.last else { throw WorkbenchError.message("未创建 SSH 桌面") }
        try await wait("SSH 桌面口令登录框") { tunneled.phase == .credentials(.password) }
        tunneled.submitCredentials(username: "", password: password, save: false)
        try await wait("SSH 桌面连接") { tunneled.phase == .connected && (tunneled.client?.statistics.frames ?? 0) >= 1 }
        guard RemoteDesktopCredentialStore.load(host: fixture.id, endpoint: try ScreenSharingEndpoint(host: "127.0.0.1", port: 5902), username: "") == nil else { throw WorkbenchError.message("未勾选保存却写入了钥匙串") }
        try await wait("第二个桌面在窗口中显示且画面与帧缓冲一致") {
            tunneled.view.window === window && tunneled.view.bounds.width > 100 && displayedMatches(tunneled)
                && (tunneled.view.displayedSnapshot() ?? []).filter { $0 & 0xFFFFFF != 0 }.count > 1000
        }
        // 从窗口服务器取实际合成后的窗口像素，在画面区多个点与帧缓冲比对（验证真正显示到屏幕，而非只是数据到达）。
        try await wait("窗口实际合成的画面与远端一致") {
            guard let client = tunneled.client, let capture = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), .bestResolution) else { return false }
            let representation = NSBitmapImageRep(cgImage: capture), frame = client.framebuffer.snapshot(), rect = tunneled.view.fitRect
            let scale = CGFloat(capture.width) / window.frame.width
            return [(0.3, 0.1), (0.5, 0.5), (0.2, 0.7), (0.9, 0.95)].allSatisfy { fx, fy in
                let remoteX = Int(CGFloat(frame.width) * fx), remoteY = Int(CGFloat(frame.height) * fy)
                let expected = frame.pixels[remoteY * frame.width + remoteX]
                let local = tunneled.view.convert(NSPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy), to: nil)
                guard let color = representation.colorAt(x: Int(local.x * scale), y: Int((window.frame.height - local.y) * scale))?.usingColorSpace(.deviceRGB) else { return false }
                let channels = [(expected >> 16) & 0xFF, (expected >> 8) & 0xFF, expected & 0xFF].map { CGFloat($0) / 255 }
                return abs(color.redComponent - channels[0]) < 0.08 && abs(color.greenComponent - channels[1]) < 0.08 && abs(color.blueComponent - channels[2]) < 0.08
            }
        }
        if let output = environment["SWB_QA_OUTPUT"], let capture = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), .bestResolution) {
            try NSBitmapImageRep(cgImage: capture).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
        if let output = environment["SWB_QA_HOLD"], let seconds = Double(output) { try await Task.sleep(for: .seconds(seconds)) }
        tunneled.close()
        try await wait("关闭 SSH 桌面") { workspace.desktops.isEmpty }
        print("PASS · 经 SSH -W 打开内嵌桌面，窗口实际合成像素与远端画面一致；未勾选保存不写钥匙串")
    }
}

