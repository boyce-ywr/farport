import AppKit
import SwiftUI
import Security
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class AppStore: ObservableObject {
    static let shared: AppStore = {
        do { return try AppStore() }
        catch { let alert = NSAlert(); alert.messageText = L10n.text("无法打开工作区"); alert.informativeText = error.localizedDescription; alert.runModal(); exit(1) }
    }()
    @Published var hosts: [HostProfile] = []
    @Published var transfers: [TransferJob] = []
    @Published var errorMessage: String?
    @Published var tunnels: [TunnelSession] = []
    @Published var screenSharingSessions: [ScreenSharingSession] = []
    @Published var webServices: [WebServiceSession] = []
    let connectionRecoveryEvents = ConnectionRecoveryEvents()
    @Published var automaticallyReconnectSSH = UserDefaults.standard.object(forKey: "automaticallyReconnectSSH") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticallyReconnectSSH, forKey: "automaticallyReconnectSSH") }
    }
    @Published var taskNotice: String?
    @Published var notifyLongTasks = UserDefaults.standard.bool(forKey: "notifyLongTasks") {
        didSet { UserDefaults.standard.set(notifyLongTasks, forKey: "notifyLongTasks") }
    }
    private var transferStarted: [UUID: Date] = [:]
    @Published var copiedFiles: FileEndpointSnapshot?
    var copiedFilesChangeCount = -1
    var draggedFiles: FileEndpointSnapshot?
    @Published var workspaceTools = WorkspaceToolsState()
    private var toolsSave: Task<Void, Never>?
    private var toolsWritable = true
    @Published var automaticallyInsertAttachments = UserDefaults.standard.object(forKey: "automaticallyInsertAttachments") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticallyInsertAttachments, forKey: "automaticallyInsertAttachments") }
    }
    @Published var useTmuxContextMenu = UserDefaults.standard.bool(forKey: "useTmuxContextMenu") {
        didSet { UserDefaults.standard.set(useTmuxContextMenu, forKey: "useTmuxContextMenu") }
    }
    func automaticallyInsertAttachments(for host: HostProfile?) -> Bool {
        let current = host.flatMap { item in hosts.first(where: { $0.id == item.id }) ?? item }
        return (current?.attachmentInsertion ?? .inherit).automatic(defaultValue: automaticallyInsertAttachments)
    }
    @Published var fontSize: Double = UserDefaults.standard.double(forKey: "fontSize") == 0 ? 13 : UserDefaults.standard.double(forKey: "fontSize")
    @Published var fontName: String = UserDefaults.standard.string(forKey: "fontName") ?? "SF Mono"
    @Published var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "system"
    @Published var languagePreference = L10n.preferenceDefaults.string(forKey: "farport.language") ?? "system" {
        didSet { L10n.preferenceDefaults.set(languagePreference, forKey: "farport.language"); L10n.setPreference(languagePreference) }
    }
    let paths: ApplicationPaths
    let transport: SSHTransport
    let isTestWorkspace: Bool
    private var active: [UUID: CancellationFlag] = [:]
    private let persistence = DispatchQueue(label: "local.sshworkbench.persistence")
    private var lastPersistence = Date.distantPast
    private var previewServers: [FilePreviewServer] = []
    func retainPreviewServer(_ server: FilePreviewServer) {
        previewServers.removeAll { !$0.isRunning }
        while previewServers.count >= 8 { previewServers.removeFirst().stop() }
        previewServers.append(server)
    }

    init() throws {
        let custom = ProcessInfo.processInfo.environment["SWB_HOME"]
        let preview = Bundle.main.bundleIdentifier == "local.sshworkbench.preview"
        isTestWorkspace = custom != nil || preview
        let root = custom.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(preview ? "Farport Preview" : "SSH Workbench")
        paths = try ApplicationPaths(root: root)
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/workbench-askpass").path
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("workbench-askpass").path
        transport = SSHTransport(paths: paths, askpass: FileManager.default.isExecutableFile(atPath: bundled) ? bundled : sibling)
        let toolsURL = paths.root.appendingPathComponent("workspace-tools.json")
        if FileManager.default.fileExists(atPath: toolsURL.path) {
            do { workspaceTools = try paths.load(WorkspaceToolsState.self, from: toolsURL) }
            catch { toolsWritable = false; errorMessage = L10n.text("无法读取工作工具记录；原文件未修改，请先检查数据目录。") }
        }
        if FileManager.default.fileExists(atPath: paths.hosts.path) { hosts = try paths.load([HostProfile].self, from: paths.hosts) }
        if FileManager.default.fileExists(atPath: paths.transfers.path) {
            transfers = try paths.load([TransferJob].self, from: paths.transfers).map { original in
                var job = original
                if job.status == .running || job.status == .queued { job.status = .paused; job.message = L10n.text("上次运行已结束；点击继续以校验断点。") }
                return job
            }
        }
    }
    var activeCount: Int { transfers.filter { $0.status == .running || $0.status == .queued }.count }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : (appearance == "light" ? .light : nil) }
    func saveHost(_ profile: HostProfile) throws {
        try profile.validate()
        if let current = hosts.first(where: { $0.id == profile.id }), current.connectionKey != profile.connectionKey,
           transfers.contains(where: { ($0.source.hostID == profile.id || $0.destination.hostID == profile.id) && ![.completed, .cancelled].contains($0.status) }) {
            throw WorkbenchError.message(L10n.text("该主机关联未完成的传输任务。请先完成或取消任务，再修改连接地址、端口、用户、密钥或跳板机。"))
        }
        if let index = hosts.firstIndex(where: { $0.id == profile.id }) { hosts[index] = profile } else { hosts.append(profile) }
        try paths.save(hosts, to: paths.hosts)
    }
    func removeHost(_ profile: HostProfile) {
        guard !transfers.contains(where: { ($0.source.hostID == profile.id || $0.destination.hostID == profile.id) && [.running, .queued, .paused, .awaitingConfirmation, .failed].contains($0.status) }) else {
            errorMessage = L10n.text("该主机关联未完成的传输任务，请先完成或取消任务。"); return
        }
        hosts.removeAll { $0.id == profile.id }
        do { try paths.save(hosts, to: paths.hosts) } catch { errorMessage = error.localizedDescription }
        forgetCredentials(profile)
    }
    func rememberSession(_ host: HostProfile, session: String) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index].lastSession = session
        do { try paths.save(hosts, to: paths.hosts) } catch { errorMessage = error.localizedDescription }
    }
    func forgetCredentials(_ profile: HostProfile) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.sshworkbench.credentials", kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var results: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &results) == errSecSuccess, let records = results as? [[String: Any]] {
            for record in records {
                if let account = record[kSecAttrAccount as String] as? String, account.hasPrefix(profile.id.uuidString + ":") {
                    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.sshworkbench.credentials", kSecAttrAccount as String: account] as CFDictionary)
                }
            }
        }
    }
    func queue(_ job: TransferJob) {
        transfers.insert(job, at: 0); persistTransfers(force: true); startNext()
    }
    func queueFiles(_ sources: [FileEndpoint], to directory: FileEndpoint, overwrite: Bool = false) throws {
        let batch = try TransferBatch.jobs(sources: sources, destinationDirectory: directory, overwrite: overwrite)
        transfers.insert(contentsOf: batch, at: 0); persistTransfers(force: true); startNext()
    }
    func pause(_ job: TransferJob) {
        active[job.id]?.cancel()
        if let index = transfers.firstIndex(where: { $0.id == job.id }), transfers[index].status == .queued { transfers[index].status = .paused }
        persistTransfers(force: true)
    }
    func resume(_ job: TransferJob) {
        guard active[job.id] == nil, job.status != .awaitingConfirmation, let index = transfers.firstIndex(where: { $0.id == job.id }) else { return }
        transfers[index].status = .queued; persistTransfers(force: true); startNext()
    }
    var pendingConflict: TransferJob? { transfers.first { $0.status == .awaitingConfirmation && active[$0.id] == nil } }
    func approveOverwrite(_ job: TransferJob) {
        guard active[job.id] == nil, let index = transfers.firstIndex(where: { $0.id == job.id }), transfers[index].status == .awaitingConfirmation,
              let conflicts = transfers[index].conflicts, !conflicts.isEmpty, conflicts.allSatisfy(\.canReplace) else { return }
        let paths = Set(conflicts.map(\.path))
        transfers[index].approvedConflicts = (transfers[index].approvedConflicts ?? []).filter { !paths.contains($0.path) } + conflicts
        transfers[index].conflicts = nil; transfers[index].status = .queued
        persistTransfers(force: true); startNext()
    }
    func clearTransferRecords(abnormalOnly: Bool = false, identifier: UUID? = nil) {
        transfers.removeAll { job in
            active[job.id] == nil && job.status.canClearRecord && (!abnormalOnly || job.status != .completed) && (identifier == nil || identifier == job.id)
        }
        persistTransfers(force: true)
    }
    func cancel(_ job: TransferJob) {
        active[job.id]?.cancel()
        if let index = transfers.firstIndex(where: { $0.id == job.id }) {
            transfers[index].status = .cancelled; transfers[index].message = L10n.text("已取消。目标目录的 .swb-*.part 断点文件保留，确认不需要后可删除。")
        }
        persistTransfers(force: true)
    }
    private func startNext() {
        while active.count < 2, let job = transfers.first(where: { $0.status == .queued && active[$0.id] == nil }) {
            let flag = CancellationFlag(); active[job.id] = flag
            transferStarted[job.id] = Date()
            let profiles = hosts; let engine = TransferEngine(transport: transport)
            Task.detached(priority: .utility) { [weak self] in
                _ = engine.execute(job, hosts: profiles, cancellation: flag) { updated in
                    DispatchQueue.main.async { self?.receive(updated) }
                }
                DispatchQueue.main.async {
                    self?.active.removeValue(forKey: job.id); self?.transferStarted.removeValue(forKey: job.id); self?.objectWillChange.send(); self?.startNext()
                }
            }
        }
    }
    private func receive(_ job: TransferJob) {
        guard let index = transfers.firstIndex(where: { $0.id == job.id }) else { return }
        let previous = transfers[index].status
        if transfers[index].status != .cancelled { transfers[index] = job }
        if previous != .cancelled, previous != job.status, [.completed, .failed, .paused, .cancelled, .awaitingConfirmation].contains(job.status), let started = transferStarted.removeValue(forKey: job.id) {
            if [.completed, .failed].contains(job.status) { notifyTaskCompletion(title: L10n.text("传输任务"), detail: job.status.title, elapsed: Date().timeIntervalSince(started), background: true) }
        }
        persistTransfers(force: job.status != .running)
    }
    func notifyTaskCompletion(title: String, detail: String, elapsed: TimeInterval, background: Bool) {
        guard notifyLongTasks, background, elapsed.isFinite, elapsed >= 30 else { return }
        taskNotice = title + " · " + detail
        if !NSApp.isActive && !isTestWorkspace { NSApp.requestUserAttention(.informationalRequest) }
    }
    func persistTransfers(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPersistence) > 0.6 else { return }; lastPersistence = Date()
        let snapshot = transfers; let paths = paths
        persistence.async { [weak self] in
            do { try paths.save(snapshot, to: paths.transfers) }
            catch { DispatchQueue.main.async { self?.errorMessage = L10n.text("保存传输断点失败：\(error.localizedDescription)") } }
        }
    }
    func prepareToQuit() {
        flushWorkspaceTools()
        previewServers.forEach { $0.stop() }; previewServers.removeAll()
        tunnels.forEach { $0.stop() }
        screenSharingSessions.forEach { $0.stop() }
        webServices.forEach { $0.stop() }
        active.values.forEach { $0.cancel() }
        for index in transfers.indices where transfers[index].status == .running || transfers[index].status == .queued { transfers[index].status = .paused }
        persistTransfers(force: true); persistence.sync {}
    }
    func saveWorkspaceTools() {
        toolsSave?.cancel()
        toolsSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flushWorkspaceTools()
        }
    }
    @discardableResult func flushWorkspaceTools() -> Bool {
        toolsSave?.cancel(); toolsSave = nil
        guard toolsWritable else { errorMessage = L10n.text("无法读取工作工具记录；原文件未修改，请先检查数据目录。"); return false }
        do { try paths.save(workspaceTools, to: paths.root.appendingPathComponent("workspace-tools.json")); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func savePreferences() {
        UserDefaults.standard.set(fontSize, forKey: "fontSize"); UserDefaults.standard.set(fontName, forKey: "fontName"); UserDefaults.standard.set(appearance, forKey: "appearance")
    }
    func importSSHConfig(_ url: URL) {
        let alert = NSAlert(); alert.messageText = L10n.text("仅导入可信的 SSH 配置"); alert.informativeText = L10n.text("SSH 配置中的 ProxyCommand / Match exec 可以执行本地命令。导入后连接将使用所选配置文件；不会复制私钥。"); alert.addButton(withTitle: L10n.text("信任并导入")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let profiles = try await Task.detached { () -> [HostProfile] in
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let aliases = text.split(separator: "\n").flatMap { line -> [String] in
                        let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                        let parts = content.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                        guard parts.first?.lowercased() == "host" else { return [] }
                        return parts.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") && !$0.hasPrefix("#") }
                    }
                    var imported: [HostProfile] = []
                    for alias in Array(Set(aliases)).sorted() {
                        var profile = HostProfile(name: alias, address: alias, group: L10n.text("SSH 配置"))
                        try profile.validate()
                        let result = try ProcessRunner.run(executable: "/usr/bin/ssh", arguments: ["-F", url.path, "-G", alias], timeout: 10).checked()
                        var values: [String: String] = [:]
                        for line in result.text.split(separator: "\n") {
                            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                            if parts.count == 2 && values[parts[0]] == nil { values[parts[0]] = parts[1] }
                        }
                        profile.port = Int(values["port"] ?? "22") ?? 22; profile.username = values["user"] ?? ""; profile.configFile = url.path
                        imported.append(profile)
                    }
                    return imported
                }.value
                for profile in profiles where !hosts.contains(where: { $0.address == profile.address && $0.configFile == profile.configFile }) { try saveHost(profile) }
                if profiles.isEmpty { errorMessage = L10n.text("该文件未包含可导入的具体 Host 别名；通配符不会转换为主机。") }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
