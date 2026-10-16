import SwiftUI
import Charts
import WorkbenchCore
import OpenSSHBackend

struct MonitorPoint: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let memory: Double?
}

@MainActor
final class HostMonitorModel: ObservableObject {
    @Published var snapshot: MonitorSnapshot?
    @Published var history: [MonitorPoint] = []
    @Published var busy = false
    @Published var paused = false
    @Published var interval = 2.0
    @Published var error: String?
    @Published var section = "overview"
    @Published var query = ""
    @Published var processOrder = "cpu"
    private(set) var platform: MonitorPlatform?
    private var cancellation = CancellationFlag()
    private var generation = UUID()
    private var previous: MonitorSnapshot?
    private var lastInfo = Date.distantPast
    let service: HostMonitorService
    init(host: HostProfile?, store: AppStore) { service = HostMonitorService(transport: store.transport, host: host) }
    func run() async {
        generation = UUID(); let run = generation
        while !Task.isCancelled && generation == run {
            let started = Date()
            if !paused { await refresh() }
            do { try await Task.sleep(for: .seconds(paused ? 0.5 : max(0.1, interval - Date().timeIntervalSince(started)))) } catch { break }
        }
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; cancellation = CancellationFlag()
        let flag = cancellation; let service = service; let platform = platform
        let includeInfo = Date().timeIntervalSince(lastInfo) >= 60
        defer { busy = false }
        do {
            var result = try await Task.detached { () -> MonitorSnapshot in
                let detected = try platform ?? service.detect(cancellation: flag)
                return try service.sample(platform: detected, includeInfo: includeInfo, cancellation: flag)
            }.value
            guard !flag.isCancelled, !Task.isCancelled else { return }
            self.platform = result.platform
            result.measure(since: previous); previous = result
            if let old = snapshot { result.info = old.info.merging(result.info, uniquingKeysWith: { _, new in new }) }
            if includeInfo { lastInfo = Date() }
            if result.processes.isEmpty && !result.warnings.contains("process-unavailable") { result.warnings.append("process-unavailable") }
            if result.networks.isEmpty && !result.warnings.contains("network-unavailable") { result.warnings.append("network-unavailable") }
            snapshot = result; error = nil
            history.append(MonitorPoint(date: result.date, cpu: result.cpuPercent, memory: result.memoryTotal.flatMap { total in total > 0 ? result.memoryUsed.map { $0 / total * 100 } : nil }))
            history.removeAll { result.date.timeIntervalSince($0.date) > 900 }
            if history.count > 900 { history.removeFirst(history.count - 900) }
        } catch {
            guard !flag.isCancelled, !Task.isCancelled else { return }
            self.error = error.localizedDescription; previous = nil
        }
    }
    func stop() { cancellation.cancel(); generation = UUID(); previous = nil }
    func togglePause() { paused.toggle(); cancellation.cancel(); previous = nil }
    var processes: [MonitorProcess] {
        (snapshot?.processes ?? []).filter { query.isEmpty || (String($0.id) + " " + $0.name + " " + $0.user).localizedCaseInsensitiveContains(query) }.sorted {
            if processOrder == "memory" { return ($0.residentBytes ?? -1) == ($1.residentBytes ?? -1) ? $0.id < $1.id : ($0.residentBytes ?? -1) > ($1.residentBytes ?? -1) }
            if processOrder == "pid" { return $0.id < $1.id }
            return ($0.cpuPercent ?? -1) == ($1.cpuPercent ?? -1) ? $0.id < $1.id : ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1)
        }
    }
}

struct HostMonitorStatusRow: View {
    let busy: Bool
    let date: Date?
    var body: some View {
        HStack {
            ZStack {
                if busy { ProgressView().controlSize(.small) }
            }.frame(width: 16, height: 16)
            Text(L10n.text("只读 · 不安装组件 · 不自动提权 · 离开页面停止采集")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let date { Text(date, style: .time).font(.caption.monospaced()).foregroundStyle(.secondary) }
        }
    }
}

struct HostMonitorWorkspace: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: AppStore
    @StateObject private var model: HostMonitorModel
    init(workspace: Workspace, store: AppStore) {
        self.workspace = workspace; self.store = store
        _model = StateObject(wrappedValue: HostMonitorModel(host: workspace.host, store: store))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("主机监控")).font(.title2.bold())
                    Text(workspace.host?.subtitle ?? L10n.text("此 Mac")).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(L10n.text("此 Mac")) { workspace.selectedHostID = nil }
                    ForEach(store.hosts) { host in Button(host.name) { workspace.selectedHostID = host.id } }
                } label: { Label(workspace.host?.name ?? L10n.text("此 Mac"), systemImage: "server.rack") }
                Picker(L10n.text("刷新间隔"), selection: $model.interval) {
                    Text("2s").tag(2.0); Text("5s").tag(5.0); Text("10s").tag(10.0)
                }.frame(width: 140)
                Button(model.paused ? L10n.text("继续采集") : L10n.text("暂停采集")) { model.togglePause() }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.busy)
            }.buttonStyle(.borderless)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                if model.snapshot != nil { Text(L10n.text("当前显示上次成功采样，不是实时数据。")).font(.caption).foregroundStyle(.orange) }
            }
            HostMonitorStatusRow(busy: model.busy, date: model.snapshot?.date)
            Picker("", selection: $model.section) {
                Text(L10n.text("概览")).tag("overview")
                Text(L10n.text("进程")).tag("processes")
                Text(L10n.text("网络与端口")).tag("network")
                Text(L10n.text("系统与用户")).tag("system")
            }.pickerStyle(.segmented).labelsHidden()
            if let snapshot = model.snapshot {
                if model.section == "processes" { processes(snapshot) }
                else if model.section == "network" { network(snapshot) }
                else if model.section == "system" { system(snapshot) }
                else { overview(snapshot) }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 40)).foregroundStyle(.teal)
                    Text(model.busy ? L10n.text("正在识别系统并采集…") : L10n.text("暂无监控数据"))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(20).task {
            if store.isTestWorkspace, let section = ProcessInfo.processInfo.environment["SWB_QA_MONITOR_SECTION"] { model.section = section }
            await model.run()
        }.onDisappear { model.stop() }
    }
    private func overview(_ snapshot: MonitorSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    card("CPU", value: percent(snapshot.cpuPercent), detail: L10n.text("整机 0–100%；首次采样可能无数据"))
                    card(L10n.text("内存"), value: size(snapshot.memoryUsed), detail: L10n.text("总计 \(size(snapshot.memoryTotal))"))
                    card(L10n.text("运行时间"), value: duration(snapshot.uptime), detail: snapshot.info["os"] ?? snapshot.platform.rawValue)
                }
                Text(L10n.text("最近 15 分钟 · 仅保留本次连接内存记录")).font(.caption).foregroundStyle(.secondary)
                Chart(model.history) { point in
                    if let cpu = point.cpu { LineMark(x: .value("Time", point.date), y: .value("%", cpu)).foregroundStyle(by: .value("Metric", "CPU")) }
                    if let memory = point.memory { LineMark(x: .value("Time", point.date), y: .value("%", memory)).foregroundStyle(by: .value("Metric", L10n.text("内存"))) }
                }.chartYScale(domain: 0...100)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second(), anchor: .top) } }
                    .chartYAxis { AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) { _ in AxisGridLine(); AxisValueLabel(anchor: .leading) } }
                    .frame(height: 120)
                Text(L10n.text("磁盘与挂载点")).font(.system(size: 12, weight: .semibold))
                if snapshot.disks.isEmpty { missing("disk-unavailable") }
                if !snapshot.disks.isEmpty { MonitorDiskList(disks: snapshot.disks) }
                capabilities(snapshot)
            }
        }
    }
    private func processes(_ snapshot: MonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L10n.text("搜索进程名、PID 或用户"), text: $model.query).textFieldStyle(.roundedBorder)
                Picker(L10n.text("排序"), selection: $model.processOrder) { Text("CPU").tag("cpu"); Text(L10n.text("内存")).tag("memory"); Text("PID").tag("pid") }.frame(width: 160)
            }
            Text(L10n.text("进程 CPU 按单核 100% 计算，可超过 100%；首个采样显示 —。内存为 RSS / Working Set，不读取命令行参数。")).font(.caption).foregroundStyle(.secondary)
            Table(model.processes) {
                TableColumn("PID") { item in Text(String(item.id)).monospacedDigit() }.width(60)
                TableColumn(L10n.text("进程")) { item in Text(item.name).lineLimit(1).help(item.name).textSelection(.enabled) }.width(min: 140, ideal: 260)
                TableColumn(L10n.text("用户 / UID")) { item in Text(item.user.isEmpty ? "—" : item.user) }.width(min: 70, ideal: 100)
                TableColumn("CPU") { item in Text(percent(item.cpuPercent)).monospacedDigit() }.width(75)
                TableColumn(L10n.text("内存")) { item in Text(size(item.residentBytes)).monospacedDigit() }.width(90)
                TableColumn(L10n.text("运行时间")) { item in Text(duration(item.elapsedSeconds)).monospacedDigit() }.width(100)
            }.font(.system(size: 11))
            Text(L10n.text("可见进程 \(snapshot.processes.count) 个。只读查看，不提供结束进程操作。")).font(.caption).foregroundStyle(.secondary)
            capabilities(snapshot)
        }
    }
    private func network(_ snapshot: MonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("网卡流量：接收为下行，发送为上行。虚拟网卡可能重复计数，因此不合并为整机总速率。")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                ForEach(snapshot.networks) { item in
                    HStack {
                        Text(item.name).font(.system(.body, design: .monospaced)).frame(width: 100, alignment: .leading)
                        Spacer(); Text("↓ \(rate(item.receiveRate))"); Spacer(); Text("↑ \(rate(item.sendRate))")
                    }.font(.caption.monospaced()).padding(10).background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                if snapshot.networks.isEmpty { missing("network-unavailable") }
            }.frame(maxHeight: 170)
            Text(L10n.text("TCP 监听 / UDP 绑定端口")).font(.headline)
            TextField(L10n.text("搜索端口、地址或 PID"), text: $model.query).textFieldStyle(.roundedBorder)
            Table(snapshot.ports.filter { model.query.isEmpty || ($0.local + " " + ($0.pid.map(String.init) ?? "") + " " + $0.transport).localizedCaseInsensitiveContains(model.query) }) {
                TableColumn(L10n.text("协议")) { item in Text(item.transport) }.width(55)
                TableColumn(L10n.text("监听地址")) { item in Text(item.local).textSelection(.enabled) }.width(min: 170, ideal: 230)
                TableColumn(L10n.text("状态")) { item in Text(item.state) }.width(80)
                TableColumn("PID") { item in Text(item.pid.map(String.init) ?? "—") }.width(65)
                TableColumn(L10n.text("进程")) { item in Text(snapshot.processes.first(where: { $0.id == item.pid })?.name ?? "—").lineLimit(1) }
            }.font(.system(size: 11))
            if snapshot.ports.isEmpty { Text(L10n.text("没有可见端口；权限或工具限制见下方说明。")).font(.caption).foregroundStyle(.secondary) }
            capabilities(snapshot)
        }
    }
    private func system(_ snapshot: MonitorSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MonitorSystemDetails(info: snapshot.info)
                Text(L10n.text("仅显示当前连接用户，不读取密码、密钥、环境变量或硬件序列号。")).font(.caption).foregroundStyle(.secondary)
                capabilities(snapshot)
            }
        }
    }
    private func capabilities(_ snapshot: MonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("权限与指标说明")).font(.caption.bold())
            ForEach(Array(Set(snapshot.warnings)).sorted(), id: \.self) { key in missing(key) }
            if snapshot.platform == .termux { Text(L10n.text("Termux 只能显示 Android 允许当前应用访问的资源；没有 root 时通常看不到全机进程和端口。")).font(.caption).foregroundStyle(.secondary) }
            if snapshot.platform == .windows { Text(L10n.text("Windows 采集适配已提供，但尚未完成 Windows 真机运行验收。")).font(.caption).foregroundStyle(.secondary) }
            Text(L10n.text("— 表示不可用或尚无差分采样，不代表零。内存口径由各系统提供，不宜直接跨系统对比。")).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func missing(_ key: String) -> some View {
        let messages = [
            "process-scope": "进程范围受当前用户权限限制；Linux 用户列可能显示 UID。",
            "process-bandwidth-unavailable": "进程级带宽：当前免安装模式不可用，不用网卡流量冒充进程流量。",
            "port-owner-permissions": "端口关联 PID 仅在系统允许时显示，不自动请求管理员权限。",
            "process-user-unavailable": "Windows 进程所属用户未采集；当前登录用户见系统信息。",
            "cpu-unavailable": "当前权限或工具无法读取整机 CPU。",
            "memory-unavailable": "当前权限或工具无法读取可比较的内存用量。",
            "network-unavailable": "无法读取网卡计数器；检查目标权限或系统工具。",
            "ports-unavailable": "端口工具缺失或权限不足，无法列出端口。",
            "process-limited": "进程采集受限：部分内存或 CPU 指标不可用。",
            "process-unavailable": "当前权限无法列出进程。",
            "system-unavailable": "部分系统信息读取失败。",
            "disk-unavailable": "无法读取磁盘使用情况。",
            "process-truncated": "进程超过 2000 项，仅展示前 2000 项。",
            "ports-truncated": "端口超过 4000 项，仅展示前 4000 项。"
        ]
        return Text(L10n.key(messages[key] ?? key)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func card(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    private func size(_ value: Double?) -> String { value.map { bytes(UInt64(max(0, min($0, Double(UInt64.max / 2))))) } ?? "—" }
    private func rate(_ value: Double?) -> String { value.map { size($0) + "/s" } ?? "—" }
    private func duration(_ value: Double?) -> String {
        guard let value else { return "—" }
        let seconds = Int(min(value, Double(Int.max / 2)))
        return String(format: "%dd %02d:%02d:%02d", seconds / 86400, seconds / 3600 % 24, seconds / 60 % 60, seconds % 60)
    }
}
