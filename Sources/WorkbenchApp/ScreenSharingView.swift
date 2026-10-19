import AppKit
import SwiftUI
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class ScreenSharingSession: ObservableObject, Identifiable {
    let id = UUID()
    let hostID: UUID
    let destination: String
    @Published private(set) var running = false
    @Published private(set) var state = ""
    @Published private(set) var localPort: Int?
    private var relay: ScreenSharingRelay?
    private var stopped = false
    init(host: HostProfile, endpoint: ScreenSharingEndpoint, throughSSH: Bool, transport: SSHTransport) throws {
        hostID = host.id; destination = endpoint.forwardingTarget
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenSharing") else {
            throw WorkbenchError.message(L10n.text("找不到 macOS 屏幕共享应用。"))
        }
        if throughSSH {
            let arguments = try transport.screenSharingArguments(for: host, endpoint: endpoint)
            let environment = transport.environment(for: host)
            state = L10n.text("正在建立本机桌面入口…"); running = true
            relay = try ScreenSharingRelay(makeProcess: {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = arguments; process.environment = environment; return process
            }, ready: { [weak self] port in
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    self.localPort = port
                    if let url = try? ScreenSharingEndpoint(host: "127.0.0.1", port: port).url { self.open(url, application: application) }
                }
            }, failure: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    self.stop(); self.state = message
                }
            })
        } else {
            guard let url = endpoint.url else { throw WorkbenchError.message(L10n.text("桌面地址无效。")) }
            open(url, application: application)
        }
    }
    private func open(_ url: URL, application: URL) {
        state = L10n.text("正在打开系统屏幕共享…")
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                if let error { self.stop(); self.state = error.localizedDescription }
                else { self.state = L10n.text("已打开系统客户端；登录与桌面状态请以系统窗口为准。") }
            }
        }
    }
    func stop() { stopped = true; relay?.stop(); relay = nil; running = false; state = L10n.text("桌面通道已停止") }
    deinit { relay?.stop() }
}

struct ScreenSharingView: View {
    let host: HostProfile
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var throughSSH = true
    @ViewState private var target = "127.0.0.1"
    @ViewState private var port = 5900
    @ViewState private var errorMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.text("远程 Mac 桌面（实验）")).font(.title2); Spacer(); Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("\(host.name) · \(host.subtitle)").font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("连接方式"), selection: $throughSSH) {
                Text(L10n.text("经 SSH 安全连接")).tag(true)
                Text(L10n.text("可信局域网 / VPN 直连")).tag(false)
            }.pickerStyle(.segmented)
                .onChange(of: throughSSH) { _, useSSH in target = useSSH ? "127.0.0.1" : host.address }
            HStack {
                VStack(alignment: .leading) { Text(throughSSH ? L10n.text("SSH 主机可访问的 Mac 地址") : L10n.text("目标 Mac 地址")); TextField(L10n.text("IP 或域名"), text: $target) }
                VStack(alignment: .leading) { Text(L10n.text("桌面端口")); TextField("5900", value: $port, format: .number.grouping(.never)) }.frame(width: 95)
            }.font(.caption).textFieldStyle(.roundedBorder)
            Text(throughSSH ? L10n.text("SSH 主机就是目标 Mac 时使用 127.0.0.1；若它只是跳板，请填写跳板可达的 Mac 地址。仅建立标准屏幕共享通道，不承诺高性能模式。") : L10n.text("仅在可信网络中直连；不会自动改走 SSH。请勿将 VNC 端口暴露到公网。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("账号由苹果屏幕共享窗口处理：使用目标 Mac 已授权的系统用户，不是 iCloud 登录；不需要自动开启传统 VNC 共享密码。Farport 不采集桌面密码，也不修改远端服务。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("SSH 模式下系统窗口显示本机转发地址，请核对此处的真实目标。此功能仍需目标 Mac 的系统账户、锁屏和多主机凭据隔离真机验收。"))
                .font(.caption).foregroundStyle(.orange)
            HStack {
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button(L10n.text("打开系统屏幕共享")) { connect() }.buttonStyle(.borderedProminent)
            }
            Divider()
            Text(L10n.text("桌面通道与终端独立；关闭此面板不会断开。退出 Farport 会关闭 SSH 桌面通道，直连窗口由系统客户端管理。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) { ForEach(store.screenSharingSessions.filter { $0.hostID == host.id }) { session in ScreenSharingRow(session: session) } }
            }.frame(height: 125)
        }.padding(24).frame(width: 660)
    }
    private func connect() {
        do {
            guard store.hosts.contains(where: { $0.id == host.id && $0.connectionKey == host.connectionKey }) else {
                throw WorkbenchError.message(L10n.text("主机配置已变化，请关闭后重新打开桌面入口。"))
            }
            let endpoint = try ScreenSharingEndpoint(host: target, port: port)
            store.screenSharingSessions.removeAll { !$0.running }
            guard store.screenSharingSessions.count < 8 else { throw WorkbenchError.message(L10n.text("请先断开不再使用的桌面通道。")) }
            let session = try ScreenSharingSession(host: host, endpoint: endpoint, throughSSH: throughSSH, transport: store.transport)
            store.screenSharingSessions.append(session); errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ScreenSharingRow: View {
    @ObservedObject var session: ScreenSharingSession
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.localPort.map { "127.0.0.1:\($0) → \(session.destination)" } ?? session.destination).font(.caption.monospaced())
                Text(session.state).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if session.running { Button(L10n.text("断开通道")) { session.stop() } }
        }.padding(8).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }
}
