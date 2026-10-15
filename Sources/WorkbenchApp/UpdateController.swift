import SwiftUI
import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()
    @Published var checking = false
    @Published var downloading = false
    @Published var progress: Double = 0
    @Published var available: ReleaseUpdate?
    @Published var downloaded: URL?
    @Published var message = L10n.text("检查 GitHub Release 获取新版本。")
    @Published var errorMessage: String?
    @Published var automaticallyCheck = UserDefaults.standard.bool(forKey: "checkForUpdates") {
        didSet { UserDefaults.standard.set(automaticallyCheck, forKey: "checkForUpdates") }
    }
    private var cancellation = CancellationFlag()
    private var generation = UUID()
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.7" }
    var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    func checkIfEnabled() {
        guard automaticallyCheck, ProcessInfo.processInfo.environment["SWB_HOME"] == nil else { return }
        let previous = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(previous) >= 86400 { check() }
    }
    func check() {
        guard !checking, !downloading else { return }
        checking = true; errorMessage = nil; message = L10n.text("正在检查 GitHub Release…"); cancellation = CancellationFlag(); generation = UUID()
        let flag = cancellation; let request = generation; let version = currentVersion; let architecture = architecture
        Task {
            defer { if generation == request { checking = false } }
            do {
                let releases = try await Task.detached { try GitHubUpdateService.releases(cancellation: flag) }.value
                guard generation == request else { return }
                available = try ReleaseUpdate.select(from: releases, current: version, architecture: architecture); downloaded = nil
                if let update = available { message = update.asset == nil ? L10n.text("发现 \(update.version.description)，但没有匹配架构且带 SHA-256 的安装包。") : L10n.text("发现新版 \(update.version.description)") }
                else { message = releases.filter({ !$0.draft && !$0.prerelease }).isEmpty ? L10n.text("仓库尚未发布正式 Release。") : L10n.text("当前版本已是最新，无需更新。") }
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            } catch { if generation == request { errorMessage = error.localizedDescription; message = L10n.text("检查更新未完成。") } }
        }
    }
    func download() {
        guard let update = available, update.asset != nil, !downloading, !checking else { return }
        downloading = true; errorMessage = nil; progress = 0; downloaded = nil; cancellation = CancellationFlag(); generation = UUID()
        let flag = cancellation; let request = generation
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Farport/Updates")
        Task {
            defer { if generation == request { downloading = false } }
            do {
                let file = try await Task.detached {
                    try GitHubUpdateService.download(update, into: root, cancellation: flag) { [weak owner = self] fraction in
                        DispatchQueue.main.async { if owner?.generation == request { owner?.progress = fraction } }
                    }
                }.value
                guard generation == request else { return }
                downloaded = file; message = L10n.text("安装包已下载，SHA-256 与磁盘映像校验通过。请在方便时确认安装。")
            } catch { if generation == request { errorMessage = error.localizedDescription; message = L10n.text("下载未完成，没有安装更新。") } }
        }
    }
    func cancel() {
        cancellation.cancel(); generation = UUID(); checking = false; downloading = false; progress = 0; message = L10n.text("已取消。不会关闭终端或安装更新。")
    }
    func openInstaller() {
        guard let downloaded else { return }
        guard confirm(L10n.text("打开已校验的安装包？"), L10n.text("请先保存工作，再按安装包说明更新。当前终端不会被自动关闭；本地 ad-hoc 签名不等于 Apple 公证。")) else { return }
        if !NSWorkspace.shared.open(downloaded) { errorMessage = L10n.text("无法打开安装包，请在 Finder 中手动打开。") }
    }
}

struct UpdateView: View {
    @ObservedObject var updater: UpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(L10n.text("Farport 软件更新"), systemImage: "arrow.down.circle").font(.title2.bold())
            Text(L10n.text("当前 \(updater.currentVersion) · \(updater.architecture) · boyce-ywr/farport")).font(.caption).foregroundStyle(.secondary)
            Text(updater.message).textSelection(.enabled)
            if let update = updater.available {
                ScrollView { Text(update.release.body?.isEmpty == false ? update.release.body! : L10n.text("此版本没有更新说明。"))
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(minHeight: 80, maxHeight: 160)
            }
            if updater.downloading { ProgressView(value: updater.progress) }
            if updater.checking { ProgressView().controlSize(.small) }
            if let error = updater.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Toggle(L10n.text("启动时自动检查（每天最多一次，不自动下载或安装）"), isOn: $updater.automaticallyCheck).font(.caption)
            Text(L10n.text("使用本机 GitHub CLI 检查 Release，不内置 Token。缺少登录时请运行：gh auth login --hostname github.com --git-protocol https --web")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button(L10n.text("检查更新")) { updater.check() }.disabled(updater.checking || updater.downloading)
                if updater.checking || updater.downloading { Button(L10n.text("取消")) { updater.cancel() } }
                Spacer()
                if let file = updater.downloaded {
                    Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    Button(L10n.text("打开安装包")) { updater.openInstaller() }.buttonStyle(.borderedProminent)
                } else if updater.available?.asset != nil {
                    Button(L10n.text("下载并校验")) { updater.download() }.buttonStyle(.borderedProminent).disabled(updater.downloading || updater.checking)
                }
            }
        }.padding(25).frame(width: 580).tint(.teal).background(.background)
    }
}
