import SwiftUI
import AppKit
import WorkbenchCore
import OpenSSHBackend
import RemoteDesktop

private struct RemoteDesktopSurface: NSViewRepresentable {
    let session: RemoteDesktopSession
    func makeNSView(context: Context) -> RemoteDesktopNSView { session.view }
    func updateNSView(_ view: RemoteDesktopNSView, context: Context) { view.framebufferChanged() }
}

/// 桌面标签内容：标题栏、画面、状态栏；独立窗口复用同一视图。
struct RemoteDesktopTab: View {
    @ObservedObject var session: RemoteDesktopSession
    var windowed = false
    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if session.poppedOut && !windowed {
                    VStack(spacing: 12) {
                        Image(systemName: "macwindow.on.rectangle").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text(L10n.text("桌面已在独立窗口中显示")).font(.headline)
                        HStack {
                            Button(L10n.text("显示窗口")) { RemoteDesktopWindows.shared.show(session) }
                            Button(L10n.text("收回到标签")) { RemoteDesktopWindows.shared.dock(session) }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RemoteDesktopSurface(session: session).id(session.id)
                    overlay
                }
            }.background(Color(red: 0.07, green: 0.08, blue: 0.09))
                .overlay(alignment: .top) {
                    if let notice = session.notice {
                        Text(notice).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule()).padding(.top, 10).allowsHitTesting(false)
                    }
                }
            statusBar
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(session.phase == .connected ? Color.teal : (session.phase == .connecting ? .orange : .secondary.opacity(0.5))).frame(width: 6, height: 6)
            Text(session.title).lineLimit(1)
            if let info = session.info, !info.name.isEmpty { Text(info.name).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
            Menu {
                Picker(L10n.text("画质"), selection: $session.quality) {
                    Text(L10n.text("清晰（无损）")).tag(RFBQuality.lossless)
                    Text(L10n.text("均衡")).tag(RFBQuality.balanced)
                    Text(L10n.text("流畅")).tag(RFBQuality.smooth)
                }.pickerStyle(.inline)
            } label: { Image(systemName: "sparkles.tv") }.menuStyle(.borderlessButton).frame(width: 26).help(L10n.text("画质"))
            Menu {
                Picker(L10n.text("⌘ 键映射"), selection: $session.commandMapping) {
                    Text(L10n.text("⌘ 作为 Command / Super（适合 macOS 远端）")).tag(RFBKeyboard.CommandMapping.native)
                    Text(L10n.text("⌘ 作为 Ctrl（适合 Linux / Windows 远端）")).tag(RFBKeyboard.CommandMapping.control)
                }.pickerStyle(.inline)
                Divider()
                Text(L10n.text("Farport 快捷键：⌃⌥F 全屏 · ⌃⌥Esc 释放键盘 · ⌃⌥W 关闭桌面"))
            } label: { Image(systemName: "keyboard") }.menuStyle(.borderlessButton).frame(width: 26).help(L10n.text("键盘映射"))
            Toggle(isOn: $session.clipboardEnabled) { Image(systemName: "doc.on.clipboard") }.toggleStyle(.button)
                .help(session.clipboardEnabled ? L10n.text("文本剪贴板同步：开（桌面获得焦点时双向同步）") : L10n.text("文本剪贴板同步：关"))
            if windowed {
                Button { RemoteDesktopWindows.shared.dock(session) } label: { Image(systemName: "rectangle.on.rectangle") }.help(L10n.text("收回到标签"))
            } else {
                Button { RemoteDesktopWindows.shared.show(session) } label: { Image(systemName: "macwindow.badge.plus") }.help(L10n.text("弹出为独立窗口"))
            }
            Button { RemoteDesktopWindows.shared.toggleFullScreen(session) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help(L10n.text("全屏 · ⌃⌥F"))
            Button { session.connect() } label: { Image(systemName: "arrow.clockwise") }.help(L10n.text("重新连接"))
            Button { session.close() } label: { Image(systemName: "xmark") }.help(L10n.text("关闭桌面 · ⌃⌥W"))
        }.font(.system(size: 10, weight: .semibold)).buttonStyle(.borderless).padding(.horizontal, 8).frame(minHeight: 30)
            .background(Color.teal.opacity(0.12))
    }

    @ViewBuilder private var overlay: some View {
        switch session.phase {
        case .connecting:
            VStack(spacing: 10) { ProgressView(); Text(session.throughSSH ? L10n.text("正在经 SSH 连接远程桌面…") : L10n.text("正在直连远程桌面…")).foregroundStyle(.secondary) }
        case .credentials(let kind):
            RemoteDesktopLogin(session: session, kind: kind)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 460).textSelection(.enabled)
                HStack {
                    Button(L10n.text("重新连接")) { session.connect() }.buttonStyle(.borderedProminent)
                    Button(L10n.text("用系统屏幕共享打开")) { RemoteDesktopWindows.shared.openSystemScreenSharing(session) }
                }
            }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .closed:
            VStack(spacing: 12) {
                Text(L10n.text("远程桌面已断开")).foregroundStyle(.secondary)
                Button(L10n.text("重新连接")) { session.connect() }
            }
        case .connected: EmptyView()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if session.throughSSH { Label(L10n.text("经 SSH 加密"), systemImage: "lock.fill").foregroundStyle(.teal) }
            else { Label(L10n.text("未加密直连"), systemImage: "exclamationmark.shield").foregroundStyle(.orange) }
            Text(session.endpoint.forwardingTarget).foregroundStyle(.secondary)
            if session.phase == .connected {
                Text("\(Int(session.size.width))×\(Int(session.size.height))")
                Text("\(session.status.fps) fps")
                Text(session.status.kilobytesPerSecond >= 1024 ? String(format: "%.1f MB/s", Double(session.status.kilobytesPerSecond) / 1024) : "\(session.status.kilobytesPerSecond) KB/s")
                if let latency = session.status.latency { Text(L10n.text("延迟约 \(Int(latency * 1000)) ms")) }
                if !session.status.encoding.isEmpty { Text(session.status.encoding) }
                if session.clipboardEnabled { Text(session.utf8Clipboard ? L10n.text("剪贴板 UTF-8") : L10n.text("剪贴板 Latin-1")).foregroundStyle(.secondary) }
            }
            Spacer()
        }.font(.system(size: 10).monospacedDigit()).padding(.horizontal, 10).frame(height: 22).background(Color.primary.opacity(0.035))
    }
}

private struct RemoteDesktopLogin: View {
    @ObservedObject var session: RemoteDesktopSession
    let kind: RFBCredentialKind
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var save = false
    @FocusState private var focus: Field?
    private enum Field { case username, password }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .usernameAndPassword ? L10n.text("登录远程 Mac") : L10n.text("输入 VNC 口令")).font(.headline)
            Text(kind == .usernameAndPassword ? L10n.text("使用目标 Mac 上有屏幕共享权限的系统用户，不是 Apple 账户，也不一定是 SSH 账号。") : L10n.text("这是远端 VNC 服务单独设置的口令。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = session.credentialError { Text(error).font(.caption).foregroundStyle(.red) }
            if kind == .usernameAndPassword {
                TextField(L10n.text("用户名"), text: $username).textFieldStyle(.roundedBorder).focused($focus, equals: .username)
            }
            SecureField(L10n.text("密码"), text: $password).textFieldStyle(.roundedBorder).focused($focus, equals: .password).onSubmit(submit)
            Toggle(L10n.text("保存到钥匙串（仅 Farport 使用）"), isOn: $save).font(.caption)
            HStack {
                Button(L10n.text("取消")) { session.cancelCredentials() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("连接"), action: submit).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || (kind == .usernameAndPassword && username.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }.padding(20).frame(width: 340).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .onAppear {
                username = session.savedUsername
                focus = kind == .usernameAndPassword && username.isEmpty ? .username : .password
            }
    }
    private func submit() {
        guard !password.isEmpty else { return }
        session.submitCredentials(username: username, password: password, save: save)
        password = ""
    }
}

/// 桌面独立窗口：弹出、收回、全屏；关闭窗口即收回到标签，不断开连接。
@MainActor
final class RemoteDesktopWindows: NSObject, NSWindowDelegate {
    static let shared = RemoteDesktopWindows()
    private var windows: [UUID: NSWindow] = [:]
    func show(_ session: RemoteDesktopSession) {
        if let window = windows[session.id] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = session.title; window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: RemoteDesktopTab(session: session, windowed: true))
        window.center(); window.delegate = self
        windows[session.id] = window
        session.poppedOut = true
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { window.makeFirstResponder(session.view) }
    }
    func dock(_ session: RemoteDesktopSession) {
        guard let window = windows.removeValue(forKey: session.id) else { session.poppedOut = false; return }
        window.delegate = nil
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        window.contentView = nil; window.close()
        session.poppedOut = false
    }
    func toggleFullScreen(_ session: RemoteDesktopSession?) {
        guard let session else { return }
        if windows[session.id] == nil { show(session) }
        windows[session.id]?.toggleFullScreen(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let identifier = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: identifier); window.contentView = nil
        sessionsByID[identifier]?.poppedOut = false
    }
    /// 关闭会话时一并关闭其窗口。
    func remove(_ session: RemoteDesktopSession) { dock(session); sessionsByID.removeValue(forKey: session.id) }
    func register(_ session: RemoteDesktopSession) { sessionsByID[session.id] = session }
    private var sessionsByID: [UUID: RemoteDesktopSession] = [:]

    /// 备用入口：内嵌客户端无法满足时改用系统屏幕共享（沿用原有 SSH 通道实现）。
    func openSystemScreenSharing(_ session: RemoteDesktopSession) { systemFallback?(session) }
    var systemFallback: ((RemoteDesktopSession) -> Void)?
}
