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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "server.rack").font(.system(size: 24)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) { Text("配置 SSH 主机").font(.title2.bold()); Text("凭据在连接时输入，不会写入配置文件。").font(.caption).foregroundStyle(.secondary) }
            }
            Form {
                TextField("显示名称", text: $profile.name)
                TextField("地址 / SSH 别名", text: $profile.address)
                HStack { TextField("用户名", text: $profile.username); TextField("端口", value: $profile.port, format: .number.grouping(.never)).frame(width: 150) }
                TextField("分组", text: $profile.group)
                HStack {
                    TextField("私钥（可留空使用 Agent）", text: $profile.identityFile)
                    Button("选择…") { let panel = NSOpenPanel(); panel.showsHiddenFiles = true; panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh"); if panel.runModal() == .OK { profile.identityFile = panel.url?.path ?? "" } }
                }
                TextField("跳板机 / ProxyJump", text: $profile.jumpHost).help("例如 user@jump:22；多级跳转使用逗号分隔。复杂配置可导入 SSH config。")
                Toggle("连接时优先打开 tmux 工作区", isOn: $profile.prefersTmux)
                Picker("标记颜色", selection: $profile.color) { Text("青绿").tag("mint"); Text("蓝色").tag("blue") }.pickerStyle(.segmented)
                if let config = profile.configFile { LabeledContent("SSH 配置文件") { Text(config).lineLimit(2).font(.caption) } }
            }.textFieldStyle(.roundedBorder)
            if !errorMessage.isEmpty { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            if let result = connectionTest.result {
                Label("\(result.detail) 用时 \(String(format: "%.1f", result.elapsed)) 秒。", systemImage: result.sftpAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(result.sftpAvailable ? Color.teal : .orange).textSelection(.enabled)
            }
            if let failure = connectionTest.failure { Text("连接失败：\(failure)").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
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
        }.padding(28).frame(width: 560).tint(.teal)
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
}
