import SwiftUI
import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class HostConnectionTest: ObservableObject {
    @Published var running = false
    @Published var result: ConnectionTestResult?
    @Published var failure: String?
    private var cancellation = CancellationFlag()
    func start(profile: HostProfile, transport: SSHTransport) {
        reset(); running = true
        let flag = cancellation
        Task {
            do {
                let checked = try await Task.detached { try transport.testConnection(profile, cancellation: flag) }.value
                guard !flag.isCancelled else { return }
                result = checked; running = false
            } catch {
                guard !flag.isCancelled else { return }
                failure = error.localizedDescription; running = false
            }
        }
    }
    func reset() {
        cancellation.cancel(); cancellation = CancellationFlag()
        running = false; result = nil; failure = nil
    }
}

struct HostEditor: View {
    @ViewState var profile: HostProfile
    @ObservedObject var store: AppStore
    let saved: (HostProfile) -> Void
    @ViewState private var errorMessage = ""
    @StateObject private var connectionTest = HostConnectionTest()
    @Environment(\.dismiss) private var dismiss
    init(profile: HostProfile, store: AppStore, saved: @escaping (HostProfile) -> Void) { _profile = State(initialValue: profile); self.store = store; self.saved = saved }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack").font(.system(size: 23)).foregroundStyle(profile.markColor)
                    .frame(width: 48, height: 48).background(profile.markColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("配置 SSH 主机").font(.system(size: 21, weight: .semibold))
                    Text("连接远方，从一个可靠的入口开始。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("连接信息", symbol: "network") {
                        HStack(alignment: .top, spacing: 16) {
                            field("显示名称") { TextField("例如：开发服务器", text: $profile.name).accessibilityIdentifier("host.name") }
                            field("分组") { TextField("我的主机", text: $profile.group) }
                        }
                        field("地址 / SSH 别名") { TextField("hostname 或 192.168.1.10", text: $profile.address).accessibilityIdentifier("host.address") }
                        HStack(alignment: .top, spacing: 16) {
                            field("用户名") { TextField("留空使用 SSH 默认用户", text: $profile.username).accessibilityIdentifier("host.username") }
                            field("端口") { TextField("22", value: $profile.port, format: .number.grouping(.never)).accessibilityIdentifier("host.port") }.frame(width: 110)
                        }
                    }
                    section("认证与跳转", symbol: "key") {
                        field("私钥文件") {
                            HStack(spacing: 8) {
                                TextField("留空使用 SSH Agent 或默认密钥", text: $profile.identityFile)
                                Button("选择…") { let panel = NSOpenPanel(); panel.showsHiddenFiles = true; panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh"); if panel.runModal() == .OK { profile.identityFile = panel.url?.path ?? "" } }
                            }
                        }
                        field("跳板机 / ProxyJump") { TextField("可选，例如 user@jump:22", text: $profile.jumpHost) }
                        Label("密码与私钥口令在连接时输入，不写入主机配置。", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
                        if let config = profile.configFile { Text("SSH 配置：\(config)").font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(config) }
                    }
                    section("工作区偏好", symbol: "rectangle.3.group") {
                        Toggle("连接时优先打开 tmux 工作区", isOn: $profile.prefersTmux).font(.system(size: 12))
                        HostColorPicker(selection: $profile.color)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.textFieldStyle(.roundedBorder).controlSize(.regular)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !errorMessage.isEmpty { Text(errorMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let result = connectionTest.result {
                    Label("\(result.detail) 用时 \(String(format: "%.1f", result.elapsed)) 秒。", systemImage: result.sftpAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(result.sftpAvailable ? Color.teal : .orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let failure = connectionTest.failure { Text("连接失败：\(failure)").font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(3).help(failure) }
            HStack {
                if connectionTest.running {
                    ProgressView().controlSize(.small)
                    Text("正在验证 SSH / SFTP…").font(.caption).foregroundStyle(.secondary)
                    Button("停止测试") { connectionTest.reset() }
                } else {
                    Button { connectionTest.start(profile: profile, transport: store.transport) } label: { Label("测试连接", systemImage: "network") }
                        .accessibilityIdentifier("host.testConnection")
                }
                Spacer()
                Button("取消") { connectionTest.reset(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存主机") { do { try store.saveHost(profile); saved(profile) } catch { errorMessage = error.localizedDescription } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(connectionTest.running)
            }
            }.padding(.horizontal, 24).padding(.vertical, 18)
        }.frame(width: 600, height: min(840, max(520, (NSScreen.main?.visibleFrame.height ?? 900) - 80))).tint(.teal)
            .onChange(of: profile.connectionKey) { _, _ in connectionTest.reset() }
            .onDisappear { connectionTest.reset() }
            .task {
                if store.isTestWorkspace && ProcessInfo.processInfo.environment["SWB_QA_SCREEN"] == "host-editor" {
                    connectionTest.start(profile: profile, transport: store.transport)
                    for _ in 0..<100 { if !connectionTest.running { break }; try? await Task.sleep(for: .milliseconds(100)) }
                    guard connectionTest.result?.sftpAvailable == true else { fputs("FAIL · 主机弹窗测试连接未通过：\(connectionTest.failure ?? connectionTest.result?.detail ?? "测试尚未完成")\n", stderr); exit(1) }
                    print("PASS · 主机弹窗显示 SSH / SFTP 测试连接成功")
                }
            }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); content().labelsHidden().accessibilityLabel(title) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)) }
    }
}
