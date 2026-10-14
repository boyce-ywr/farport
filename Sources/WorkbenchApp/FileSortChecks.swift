import AppKit
import Foundation
import WorkbenchCore

@MainActor
enum FileSortChecks {
    static func run(workspace: Workspace) async throws {
        let root = workspace.store.paths.root.appendingPathComponent("sort-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, content) in [("file10.txt", "short"), ("file2.py", "longer python text"), ("README.md", "# Sorting") ] {
            try Data(content.utf8).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        workspace.browseFiles(.local)
        guard let model = workspace.currentFileBrowser else { throw WorkbenchError.message("文件模型不可用") }
        try await wait { !model.busy }
        model.load(root.path)
        try await wait { !model.busy && model.path == root.path }
        model.selection = [root.appendingPathComponent("file2.py").path]
        try await Task.sleep(for: .milliseconds(500))
        let defaults = model.visibleFiles.map(\.path); let selection = model.selection
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let table = findTable(child) { return table } }
            return nil
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let content = window.contentView,
              let table = findTable(content), let header = table.headerView else { throw WorkbenchError.message("找不到原生文件表头") }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        for column in FileSortColumn.allCases {
            guard let columnIndex = table.tableColumns.firstIndex(where: { $0.title == column.title }) else { throw WorkbenchError.message("缺少列：\(column.title)") }
            for click in 1...3 {
                table.scrollColumnToVisible(columnIndex)
                let rect = header.headerRect(ofColumn: columnIndex)
                let point = header.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: click, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false); try await Task.sleep(for: .milliseconds(80))
                    }
                }
                try await Task.sleep(for: .milliseconds(200))
                try await wait { click == 3 ? model.fileSort.column == nil : (model.fileSort.column == column && model.fileSort.descending == (click == 2)) }
                guard model.selection == selection else { throw WorkbenchError.message("排序改变文件选择") }
            }
            guard model.visibleFiles.map(\.path) == defaults else { throw WorkbenchError.message("第三次点击没有恢复默认顺序") }
        }
        let host = workspace.store.hosts.first
        if let host {
            model.fileSort.cycle(.size)
            let order = model.fileSort
            workspace.browseFiles(.host(host.id)); workspace.browseFiles(.local)
            guard workspace.currentFileBrowser === model, model.fileSort == order else { throw WorkbenchError.message("来源切换丢失排序状态") }
        }
        print("PASS · 五列原生表头 15 次点击：升序/降序/默认、选择保留与来源独立排序")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("表头排序验证超时") }; try await Task.sleep(for: .milliseconds(80)) }
    }
}
