import AppKit
import SwiftUI
import WorkbenchCore

@MainActor
enum MonitorProcessSortChecks {
    static func run(store: AppStore, output: URL) async throws {
        let model = HostMonitorModel(host: nil, store: store)
        var snapshot = try MonitorSnapshot.parse("FARPORT_MONITOR_V1\nprocess\t10\talice\t1024\t1\t7200\tworker10\ta\nprocess\t2\tbob\t2048\t1\t120\tworker2\tb\nprocess\t30\t\t\t1\t\tworker30\tc\n", platform: .linux)
        snapshot.processes[0].cpuPercent = 90; snapshot.processes[1].cpuPercent = 9
        model.snapshot = snapshot
        let hosting = NSHostingView(rootView: MonitorProcessTable(model: model).frame(minWidth: 820, minHeight: 480).environment(\.locale, L10n.language.locale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hosting; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        guard let table = findTable(hosting), let header = table.headerView else { throw WorkbenchError.message("找不到监控原生表头") }
        for width in [CGFloat(820), 1180] {
            window.setContentSize(NSSize(width: width, height: 480)); hosting.layoutSubtreeIfNeeded()
            for column in MonitorProcessColumn.allCases {
                guard let index = table.tableColumns.firstIndex(where: { $0.title == column.title }) else { throw WorkbenchError.message("缺少监控列：\(column)") }
                for click in 1...3 {
                    table.scrollColumnToVisible(index)
                    let rect = header.headerRect(ofColumn: index)
                    let point = header.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: click, clickCount: 1, pressure: 1) else { throw WorkbenchError.message("不能创建表头点击事件") }
                        NSApp.postEvent(event, atStart: false); try await Task.sleep(for: .milliseconds(80))
                    }
                    guard click == 3 ? model.processSort.column == nil : (model.processSort.column == column && model.processSort.descending == (click == 2)) else { throw WorkbenchError.message("表头\(column)第\(click)次点击状态错误") }
                    let order = click == 1 ? SortOrder.forward : .reverse
                    let expected = snapshot.processes.sorted(using: MonitorProcessComparator(column: click == 3 ? .cpu : column, order: order)).map(\.id)
                    guard model.processes.map(\.id) == expected else { throw WorkbenchError.message("表头状态与行顺序不一致") }
                    if click != 3 {
                        guard let descriptor = table.sortDescriptors.first, descriptor.ascending == (click == 1) else { throw WorkbenchError.message("表头没有同步排序箭头") }
                    } else { guard table.sortDescriptors.isEmpty else { throw WorkbenchError.message("默认排序没有移除列箭头") } }
                    let before = model.processSort
                    var refreshed = snapshot; refreshed.processes.reverse(); model.snapshot = refreshed
                    guard model.processSort == before && model.processes.map(\.id) == expected else { throw WorkbenchError.message("刷新导致排序丢失") }
                    model.query = "worker"
                    guard model.processSort == before else { throw WorkbenchError.message("筛选改变排序选择") }
                    model.query = ""
                }
            }
        }
        model.processSort.cycle(.memory); model.processSort.cycle(.memory)
        try await Task.sleep(for: .milliseconds(200))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw WorkbenchError.message("无法截图监控排序") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        print("PASS · 监控六列原生表头36次点击、两种宽度、箭头、三态排序、刷新和筛选保持")
    }
    private static func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable($0) }.first
    }
}
