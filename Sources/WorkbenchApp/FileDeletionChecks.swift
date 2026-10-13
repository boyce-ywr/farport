import AppKit
import Foundation
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum FileDeletionChecks {
    static func run(workspace: Workspace) async throws {
        try await check(workspace: workspace, host: nil)
        if let host = workspace.store.hosts.first, host.address == "127.0.0.1", [22281, 22282].contains(host.port) {
            try await check(workspace: workspace, host: host)
        }
        print("PASS · 本机/SSH 批量删除文件及嵌套目录、保留未选项、部分失败保留选择、菜单多选与未选中行语义")
    }
    private static func check(workspace: Workspace, host: HostProfile?) async throws {
        let transport = workspace.store.transport
        let directory = (host == nil ? workspace.store.paths.root.path : "/tmp") + "/farport-delete-check-" + UUID().uuidString
        try await Task.detached {
            let client = try transport.files(host); defer { client.close() }
            try client.mkdir(directory)
            for name in ["keep.txt", "picked.txt", "gone.txt"] { try client.createFile(directory + "/" + name) }
            try client.mkdir(directory + "/folder"); try client.createFile(directory + "/folder/nested.txt")
        }.value
        workspace.browseFiles(host.map { .host($0.id) } ?? .local)
        guard let model = workspace.currentFileBrowser else { throw WorkbenchError.message("缺少文件浏览模型") }
        try await wait { !model.busy }
        model.load(directory)
        try await wait { !model.busy && model.path == directory && model.files.count == 4 }
        model.selection = Set(model.files.filter { $0.name != "keep.txt" }.map(\.path))
        let targets = model.selectedFiles
        guard targets.count == 3 else { throw WorkbenchError.message("文件多选未生效") }
        try await Task.sleep(for: .milliseconds(250))
        try await checkMenu(model: model, clickedName: "picked.txt", expectedTitle: "删除 3 项…")
        try await checkMenu(model: model, clickedName: "keep.txt", expectedTitle: "删除…")
        model.selection = Set(targets.map(\.path))
        try await Task.detached {
            let client = try transport.files(host); defer { client.close() }; try client.removeRecursively(directory + "/gone.txt")
        }.value
        model.deleteFiles(targets)
        try await wait { !model.busy }
        guard model.files.map(\.name).sorted() == ["gone.txt", "keep.txt"], model.selection == [directory + "/gone.txt"],
              model.errorMessage?.contains("已删除 2 项") == true else { throw WorkbenchError.message("部分失败状态：source=\(host == nil ? "local" : "ssh")，files=\(model.files.map(\.name))，selection=\(model.selection.map { ($0 as NSString).lastPathComponent })，error=\(model.errorMessage ?? "nil")") }
        let remaining = try await Task.detached { () -> [String] in
            let client = try transport.files(host); defer { client.close() }
            return try client.list(directory).map(\.name)
        }.value
        guard remaining == ["keep.txt"] else { throw WorkbenchError.message("未选中文件被误删或选中目录未递归删除") }
        model.errorMessage = nil; model.load(directory)
        try await wait { !model.busy }
        try await Task.detached {
            let client = try transport.files(host); defer { client.close() }; try client.removeRecursively(directory)
        }.value
        model.load(host == nil ? workspace.store.paths.root.path : "/tmp")
        try await wait { !model.busy }
    }
    private static func checkMenu(model: FileModel, clickedName: String, expectedTitle: String) async throws {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let table = find(child) { return table } }
            return nil
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let content = window.contentView,
              let table = find(content), let row = model.visibleFiles.firstIndex(where: { $0.name == clickedName }) else { throw WorkbenchError.message("未找到文件表格") }
        window.makeKeyAndOrderFront(nil)
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: 80, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw WorkbenchError.message("无法创建右键事件") }
        guard let menu = table.menu(for: event) else { throw WorkbenchError.message("原生表格没有提供上下文菜单") }
        menu.delegate?.menuNeedsUpdate?(menu); menu.delegate?.menuWillOpen?(menu)
        let titles = menu.items.map(\.title)
        menu.delegate?.menuDidClose?(menu)
        guard titles.contains(expectedTitle) else { throw WorkbenchError.message("右键菜单目标不正确：\(titles)") }
    }
    private static func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition() { guard Date() < end else { throw WorkbenchError.message("文件删除验证超时：检查点 \(line)") }; try await Task.sleep(for: .milliseconds(80)) }
    }
}
