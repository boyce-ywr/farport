import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum UpgradeCompatibilityChecks {
    static func run(store: AppStore) throws {
        guard Bundle.main.bundleIdentifier == "local.sshworkbench.mac",
              Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Farport" else {
            throw WorkbenchError.message("升级验收必须使用正式身份的安装包")
        }
        let baseline = store.paths.root.appendingPathComponent("upgrade-baseline")
        let hosts = try JSONDecoder().decode([HostProfile].self, from: Data(contentsOf: baseline.appendingPathComponent("hosts.json")))
        let jobs = try JSONDecoder().decode([TransferJob].self, from: Data(contentsOf: baseline.appendingPathComponent("transfers.json")))
        let knownHosts = try Data(contentsOf: baseline.appendingPathComponent("known_hosts"))
        guard store.hosts == hosts, !hosts.isEmpty, store.transfers.map(\.id) == jobs.map(\.id),
              try Data(contentsOf: store.paths.knownHosts) == knownHosts else {
            throw WorkbenchError.message("旧版主机、指纹或传输记录未完整读取")
        }
        guard store.fontSize == 17, store.fontName == "Menlo", store.appearance == "dark",
              store.useTmuxContextMenu else {
            throw WorkbenchError.message("原有偏好设置键读取不一致")
        }
        try verifyJobs(store.transfers, baseline: jobs)
        guard store.activeCount == 0, store.tunnels.isEmpty, store.screenSharingSessions.isEmpty, store.webServices.isEmpty else {
            throw WorkbenchError.message("升级时不应自动恢复传输或通道")
        }
        for host in hosts { try store.saveHost(host) }
        store.prepareToQuit()
        guard store.errorMessage == nil else { throw WorkbenchError.message("升级后的记录保存失败") }
        let reloaded = try AppStore()
        guard reloaded.hosts == hosts, try Data(contentsOf: reloaded.paths.knownHosts) == knownHosts else {
            throw WorkbenchError.message("升级保存后重新读取丢失主机或指纹")
        }
        try verifyJobs(reloaded.transfers, baseline: jobs)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.paths.hosts.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw WorkbenchError.message("升级保存后主机文件权限不再私有")
        }
        print("PASS · 正式身份读取旧版主机/设置键/指纹/传输断点，未完成任务暂停且不自动恢复，保存重读一致")
        fflush(stdout)
    }
    private static func verifyJobs(_ actual: [TransferJob], baseline: [TransferJob]) throws {
        guard actual.count == baseline.count else { throw WorkbenchError.message("旧传输记录数量改变") }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for (loaded, original) in zip(actual, baseline) {
            var expected = original
            if original.status == .running || original.status == .queued {
                expected.status = .paused; expected.message = loaded.message
            }
            guard try encoder.encode(loaded) == encoder.encode(expected) else {
                throw WorkbenchError.message("旧传输的身份、进度、路径、状态或条目发生非预期变化")
            }
        }
    }
}
