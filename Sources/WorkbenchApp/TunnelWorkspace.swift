import SwiftUI
import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class TunnelSession: ObservableObject, Identifiable {
    let id = UUID()
    let host: HostProfile
    let mode: String
    let port: Int
    let destination: String
    @Published var state = L10n.text("正在连接…")
    @Published var running = false
    private let process = Process()
    private let stderrPipe = Pipe()
    init(host: HostProfile, mode: String, port: Int, target: String, targetPort: Int, transport: SSHTransport) throws {
        self.host = host; self.mode = mode; self.port = port
        destination = mode == "SOCKS5" ? L10n.text("动态代理") : "\(target):\(targetPort)"
        let kind: ForwardingKind = mode == L10n.text("本地转发") ? .local : (mode == L10n.text("远程转发") ? .remote : .dynamic)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try transport.forwardingArguments(for: host, kind: kind, port: port, target: target, targetPort: targetPort)
        process.environment = transport.environment(for: host); process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = stderrPipe
        let errorHandle = stderrPipe.fileHandleForReading
        process.terminationHandler = { [weak self] child in
            let data = (try? errorHandle.readToEnd()) ?? Data()
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false; self.state = child.terminationStatus == 0 ? L10n.text("已停止") : String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if self.state.isEmpty { self.state = L10n.text("隧道已停止") }
            }
        }
        try process.run(); running = true; state = L10n.text("隧道进程运行中")
    }
    func stop() { if process.isRunning { process.terminate() }; running = false; state = L10n.text("已停止") }
}

struct TunnelWorkspace: View {
    let host: HostProfile
    @ObservedObject var store: AppStore
    @ViewState private var mode = L10n.text("本地转发")
    @ViewState private var port = 8080
    @ViewState private var target = "127.0.0.1"
    @ViewState private var targetPort = 80
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) { Text(L10n.text("把服务安全地带到身边")).font(.system(size: 23, weight: .semibold)); Text(L10n.text("通过 SSH 加密通道访问服务；与终端会话相互独立。")).font(.system(size: 12)).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 17) {
                Picker(L10n.text("转发模式"), selection: $mode) { Text(L10n.text("本地转发")).tag(L10n.text("本地转发")); Text(L10n.text("远程转发")).tag(L10n.text("远程转发")); Text("SOCKS5").tag("SOCKS5") }.pickerStyle(.segmented)
                HStack(spacing: 14) {
                    VStack(alignment: .leading) { Text(mode == L10n.text("远程转发") ? L10n.text("远端监听端口") : L10n.text("本机监听端口")).font(.caption).foregroundStyle(.secondary); TextField(L10n.text("端口"), value: $port, format: .number.grouping(.never)) }.frame(width: 160)
                    if mode != "SOCKS5" {
                        Image(systemName: "arrow.right").foregroundStyle(.teal)
                        VStack(alignment: .leading) { Text(mode == L10n.text("远程转发") ? L10n.text("本机可访问的目标") : L10n.text("远端可访问的目标")).font(.caption).foregroundStyle(.secondary); TextField(L10n.text("目标主机"), text: $target) }
                        VStack(alignment: .leading) { Text(L10n.text("目标端口")).font(.caption).foregroundStyle(.secondary); TextField(L10n.text("端口"), value: $targetPort, format: .number.grouping(.never)) }.frame(width: 130)
                    }
                    Spacer(minLength: 0)
                    Button(L10n.text("启动隧道")) { do { let tunnel = try TunnelSession(host: host, mode: mode, port: port, target: target, targetPort: targetPort, transport: store.transport); store.tunnels.append(tunnel) } catch { store.errorMessage = error.localizedDescription } }.buttonStyle(.borderedProminent)
                }.textFieldStyle(.roundedBorder)
                Label(L10n.text("请求绑定 127.0.0.1，不主动向局域网开放端口。切换工作区不会停止隧道；退出应用时停止。"), systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(22).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            Text(L10n.text("运行记录")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView { VStack(spacing: 12) { ForEach(store.tunnels.filter { $0.host.id == host.id }) { tunnel in TunnelRow(tunnel: tunnel) } } }
        }.padding(26)
    }
}

struct TunnelRow: View {
    @ObservedObject var tunnel: TunnelSession
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 5) { Text("\(tunnel.mode) · 127.0.0.1:\(tunnel.port) → \(tunnel.destination)").font(.system(size: 12, design: .monospaced)); Text(tunnel.state).font(.system(size: 10)).foregroundStyle(tunnel.running ? .secondary : Color.orange).textSelection(.enabled) }
            Spacer(); if tunnel.running { Button(L10n.text("停止")) { tunnel.stop() } }
        }.padding(18).background(.quaternary.opacity(0.17), in: RoundedRectangle(cornerRadius: 10))
    }
}
