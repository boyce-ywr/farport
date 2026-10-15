import AppKit
import Foundation
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum MonitoringChecks {
    static func run(workspace: Workspace) async throws {
        let service = HostMonitorService(transport: workspace.store.transport, host: workspace.host)
        if let host = workspace.host {
            guard host.address == "127.0.0.1", [22281, 22282].contains(host.port) else { throw WorkbenchError.message("只测试隔离监控主机") }
        }
        let flag = CancellationFlag()
        let platform = try await Task.detached { try service.detect(cancellation: flag) }.value
        let first = try await Task.detached { try service.sample(platform: platform, includeInfo: true, cancellation: flag) }.value
        try await Task.sleep(for: .seconds(1))
        var second = try await Task.detached { try service.sample(platform: platform, includeInfo: false, cancellation: flag) }.value
        second.measure(since: first)
        guard !first.info.isEmpty, first.info["username"]?.isEmpty == false, !second.processes.isEmpty, second.memoryTotal != nil else { throw WorkbenchError.message("真实监控缺少用户/进程/内存数据") }
        guard second.cpuPercent != nil else { throw WorkbenchError.message("CPU 差分或平台采样失败") }
        let model = HostMonitorModel(host: workspace.host, store: workspace.store)
        await model.refresh()
        guard model.snapshot != nil, model.error == nil else { throw WorkbenchError.message("监控模型采样失败") }
        model.togglePause()
        let before = model.snapshot?.date
        let task = Task { await model.run() }
        try await Task.sleep(for: .milliseconds(600))
        guard model.snapshot?.date == before else { throw WorkbenchError.message("暂停期间仍自动采样") }
        model.stop(); task.cancel()
        flag.cancel()
        do { _ = try await Task.detached { try service.sample(platform: platform, includeInfo: false, cancellation: flag) }.value; throw WorkbenchError.message("取消后仍执行监控") }
        catch WorkbenchError.cancelled {}
        workspace.page = .monitor
        print("PASS · \(platform.rawValue) 真实只读采集：\(second.processes.count) 进程、\(second.networks.count) 网卡、\(second.disks.count) 挂载点；用户信息、暂停和取消检查")
    }
}
