import AppKit
import Foundation
import WorkbenchCore

@MainActor
enum LargeDirectoryChecks {
    static func run(workspace: Workspace, directory: String) async throws {
        guard let host = workspace.host else { throw WorkbenchError.message("缺少只读测试主机") }
        workspace.browseFiles(.host(host.id))
        guard let model = workspace.currentFileBrowser else { throw WorkbenchError.message("缺少文件浏览模型") }
        try await wait { !model.busy }
        let parent = RemotePath.parent(directory)
        model.load(parent)
        try await wait { !model.busy }
        guard model.path == parent, model.errorMessage == nil,
              let row = model.visibleFiles.firstIndex(where: { $0.path == directory && $0.attributes.isDirectory }),
              let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let table = findTable(content), let window = table.window else { throw WorkbenchError.message("找不到待打开目录或原生文件表格") }
        try await wait { table.numberOfRows == model.visibleFiles.count }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        content.layoutSubtreeIfNeeded(); table.scrollRowToVisible(row)
        try await Task.sleep(for: .milliseconds(200))
        let rectangle = table.rect(ofRow: row)
        let position = table.convert(NSPoint(x: rectangle.minX + 60, y: rectangle.midY), to: nil)
        for click in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: click, clickCount: click, pressure: type == .leftMouseDown ? 1 : 0) else { throw WorkbenchError.message("无法生成目录点击事件") }
                NSApp.postEvent(event, atStart: false)
                try await Task.sleep(for: .milliseconds(50))
            }
            if click == 1 {
                guard model.path == parent, !model.busy, model.selection == [directory] else { throw WorkbenchError.message("单击目录应只选中") }
                print("PASS · 真实设备目录单击只选中")
            }
        }
        let started = Date()
        print("目录双击已发送，加载状态：\(model.busy)"); fflush(stdout)
        guard model.busy, model.loadingPath == directory else { throw WorkbenchError.message("双击后没有目标目录加载反馈") }
        try await wait { model.loadedEntryCount > 0 || !model.busy }
        guard model.busy, model.loadedEntryCount > 0 else { throw WorkbenchError.message("大目录读取期间没有条目进度") }
        let countBeforeRepeat = model.loadedEntryCount
        model.activate(model.files.first { $0.path == directory }!)
        guard model.loadedEntryCount == countBeforeRepeat else { throw WorkbenchError.message("重复双击重新开始了同一目录读取") }
        try await wait { model.loadedEntryCount > countBeforeRepeat || !model.busy }
        print("PASS · 大目录读取进度可见，重复打开没有重置请求"); fflush(stdout)
        try await wait { !model.busy }
        guard model.path == directory, model.errorMessage == nil, !model.files.isEmpty else { throw WorkbenchError.message("双击未进入目录：\(model.errorMessage ?? "路径未变化")") }
        print("PASS · 真实设备双击进入目录：\(model.files.count) 项，\(String(format: "%.3f", Date().timeIntervalSince(started))) 秒"); fflush(stdout)
        try await wait { table.numberOfRows == model.visibleFiles.count }
        let readsStarted = Date()
        var count = 0
        for _ in 0..<20 { count += model.visibleFiles.count; count += model.selectedFiles.count }
        let elapsed = Date().timeIntervalSince(readsStarted)
        guard count > 0, elapsed < 0.2 else { throw WorkbenchError.message("大目录重复读取阻塞主线程：\(String(format: "%.3f", elapsed)) 秒") }
        print("PASS · 大目录重复视图读取 \(String(format: "%.3f", elapsed)) 秒，原生表格行数一致")
        let originalLanguage = L10n.language
        let originalFiles = model.files
        func verifyCache() throws {
            let expected = model.fileSort.sorted(model.files.filter { (model.showHidden || !$0.name.hasPrefix(".")) && (model.filter.isEmpty || $0.name.localizedCaseInsensitiveContains(model.filter)) })
            guard model.visibleFiles == expected else { throw WorkbenchError.message("筛选、排序或语言变化后列表缓存未失效") }
        }
        model.filter = "__farport_absent_" + UUID().uuidString; try verifyCache()
        model.filter = ""; try verifyCache()
        model.showHidden.toggle(); try verifyCache()
        model.fileSort.cycle(.size); try verifyCache()
        model.fileSort.cycle(.size); try verifyCache()
        model.fileSort.cycle(.type); try verifyCache()
        L10n.setPreference("en"); try verifyCache()
        L10n.setPreference("zh-Hans"); try verifyCache()
        L10n.setPreference(originalLanguage.rawValue)
        model.files = []; try verifyCache()
        model.files = originalFiles; model.fileSort = FileSort(); try verifyCache()
        print("PASS · 列表变化、隐藏项、筛选、排序和中英文切换均正确更新缓存")
        model.load(parent); try await wait { !model.busy }
        guard model.path == parent else { throw WorkbenchError.message("未返回原目录") }
        model.load(directory)
        try await wait { model.loadedEntryCount > 0 || !model.busy }
        guard model.busy, model.loadedEntryCount > 0 else { throw WorkbenchError.message("取消检查没有覆盖实际目录读取") }
        model.stop()
        try await Task.sleep(for: .milliseconds(500))
        guard !model.busy, model.loadingPath == nil, model.loadedEntryCount == 0, model.path == parent else { throw WorkbenchError.message("取消目录读取后旧请求回写状态") }
        print("PASS · 取消读取保留原目录，旧进度不回写"); fflush(stdout)
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            guard Date() < deadline else { throw WorkbenchError.message("目录导航验证超时") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private static func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = findTable(child) { return table } }
        return nil
    }
}
