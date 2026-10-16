import SwiftUI
import WorkbenchCore

struct MonitorProcessTable: View {
    @ObservedObject var model: HostMonitorModel
    var body: some View {
        Table(model.processes, sortOrder: $model.processOrder) {
            TableColumn("PID", sortUsing: MonitorProcessComparator(column: .pid)) { item in Text(String(item.id)).monospacedDigit() }.width(60)
            TableColumn(L10n.text("进程"), sortUsing: MonitorProcessComparator(column: .name)) { item in Text(item.name).lineLimit(1).help(item.name).textSelection(.enabled) }.width(min: 140, ideal: 260)
            TableColumn(L10n.text("用户 / UID"), sortUsing: MonitorProcessComparator(column: .user)) { item in Text(item.user.isEmpty ? "—" : item.user) }.width(min: 70, ideal: 100)
            TableColumn("CPU", sortUsing: MonitorProcessComparator(column: .cpu)) { item in Text(item.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—").monospacedDigit() }.width(75)
            TableColumn(L10n.text("内存"), sortUsing: MonitorProcessComparator(column: .memory)) { item in Text(item.residentBytes.map { bytes(UInt64(max(0, min($0, Double(UInt64.max / 2))))) } ?? "—").monospacedDigit() }.width(90)
            TableColumn(L10n.text("运行时间"), sortUsing: MonitorProcessComparator(column: .uptime)) { item in Text(duration(item.elapsedSeconds)).monospacedDigit() }.width(100)
        }.font(.system(size: 11))
            .background(TableHeaderSorting(titles: MonitorProcessColumn.allCases.map(\.title)) { model.processSort.cycle(MonitorProcessColumn.allCases[$0]) }.frame(width: 0, height: 0))
            .help(L10n.text("点击表头切换升序、降序、默认；缺失值始终在末尾。"))
    }
    private func duration(_ value: Double?) -> String {
        guard let value else { return "—" }
        let seconds = Int(min(value, Double(Int.max / 2)))
        return String(format: "%dd %02d:%02d:%02d", seconds / 86400, seconds / 3600 % 24, seconds / 60 % 60, seconds % 60)
    }
}
