import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore
import OpenSSHBackend


@MainActor
enum FilePaneChecks {
    static func runModels(store: AppStore) async throws {
        let workspace = Workspace(store: store)
        let root = store.paths.root.appendingPathComponent("file-pane-models")
        let first = root.appendingPathComponent("source"); let second = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let source = first.appendingPathComponent("文件 a.txt")
        let bytes = Data("file-pane-content".utf8); try bytes.write(to: source)
        workspace.browseFiles(.local)
        guard let original = workspace.currentFileBrowser else { throw WorkbenchError.message("没有初始文件分栏") }
        original.load(first.path)
        try await wait { !original.busy && original.path == first.path }
        original.filter = "a.txt"; original.selection = [source.path]
        let terminalLayout = workspace.layout
        workspace.splitFilePane()
        guard let destination = workspace.currentFileBrowser, destination !== original else { throw WorkbenchError.message("分栏共享了文件浏览模型") }
        defer { workspace.filePanes.forEach { $0.stop() } }
        destination.load(second.path)
        try await wait { !destination.busy && destination.path == second.path }
        guard original.path == first.path, original.filter == "a.txt", original.selection == [source.path],
              destination.filter.isEmpty, destination.selection.isEmpty, !original.showPreview, !destination.showPreview,
              !original.previewBusy, workspace.layout == terminalLayout else {
            throw WorkbenchError.message("分栏互相覆盖目录/筛选/选择，或修改了终端布局")
        }
        let pane = workspace.focusedFilePane!
        let session = TerminalSession(transport: store.transport)
        workspace.sessions.append(session)
        workspace.selectFileSource(.terminal(session.id), in: pane)
        guard workspace.currentFileBrowser !== destination else { throw WorkbenchError.message("不同来源复用了同一浏览状态") }
        workspace.selectFileSource(.local, in: pane)
        guard workspace.currentFileBrowser === destination, destination.path == second.path else { throw WorkbenchError.message("切回来源丢失目录状态") }
        workspace.close(session)
        workspace.splitFilePane(axis: .topBottom)
        guard workspace.filePanes.count == 3 else { throw WorkbenchError.message("嵌套上下分栏失败") }
        workspace.closeFilePane(workspace.fileLayout.focused!)
        guard workspace.filePanes.count == 2, original.path == first.path, destination.path == second.path else { throw WorkbenchError.message("关闭分栏改变了其他目录") }
        try await checkClipboard(store: store, file: source)
        let references = try FileEndpointSnapshot(endpoints: [FileEndpoint(path: source.path)], hosts: store.hosts)
        let target = try FileEndpointSnapshot(endpoints: [FileEndpoint(path: second.path)], hosts: store.hosts)
        try store.queueFileReferences(references, to: target)
        try await wait { store.activeCount == 0 }
        guard try Data(contentsOf: second.appendingPathComponent(source.lastPathComponent)) == bytes else { throw WorkbenchError.message("文件引用没有进入实际复制队列") }
        try Data("changed".utf8).write(to: source)
        try store.queueFileReferences(references, to: target)
        try await wait { store.pendingConflict != nil }
        guard try Data(contentsOf: second.appendingPathComponent(source.lastPathComponent)) == bytes else { throw WorkbenchError.message("覆盖确认前改变了目标文件") }
        store.approveOverwrite(store.pendingConflict!)
        try await wait { store.activeCount == 0 }
        guard try Data(contentsOf: second.appendingPathComponent(source.lastPathComponent)) == Data("changed".utf8) else { throw WorkbenchError.message("确认覆盖后内容不正确") }
        try await checkDropGuards(store: store, model: destination, source: source)
        print("PASS · 文件分栏独立模型/来源缓存/嵌套关闭、剪贴板令牌/身份保护、真实复制与覆盖确认")
        fflush(stdout)
    }
    private static func checkClipboard(store: AppStore, file: URL) async throws {
        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            board.clearContents()
            if let previous { board.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        let endpoints = [FileEndpoint(path: file.path)]
        try store.copyFileReferences(endpoints)
        guard store.fileClipboard == endpoints, board.string(forType: .string) == nil else { throw WorkbenchError.message("文件复制暴露了文本路径或没有写入引用") }
        var rejected = false
        do { try store.copyFileReferences([]) } catch { rejected = true }
        guard rejected, !store.fileClipboard.isEmpty else { throw WorkbenchError.message("空选择复制未拒绝或改变了剪贴板") }
        board.clearContents(); board.setString("text clipboard", forType: .string)
        guard store.fileClipboard.isEmpty else { throw WorkbenchError.message("其他文本复制后仍使用旧文件剪贴板") }
        board.clearContents(); board.writeObjects([file as NSURL])
        guard try store.pastedFileReferences().endpoints == endpoints else { throw WorkbenchError.message("Finder 文件剪贴板未识别") }
        var host = HostProfile(name: "snapshot fixture", address: "old.invalid")
        store.hosts.append(host)
        defer { store.hosts.removeAll { $0.id == host.id } }
        try store.copyFileReferences([FileEndpoint(hostID: host.id, path: "/file")])
        host.address = "changed.invalid"; store.hosts[store.hosts.firstIndex(where: { $0.id == host.id })!] = host
        rejected = false
        do { _ = try store.pastedFileReferences() } catch { rejected = true }
        guard rejected else { throw WorkbenchError.message("主机改变后仍接受旧复制来源") }
        let provider = try store.fileDragProvider(endpoints)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.workbenchFiles.identifier) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? WorkbenchError.message("没有拖拽数据")) }
            }
        }
        guard try store.draggedFileReferences(data).endpoints == endpoints, String(data: data, encoding: .utf8)?.contains(file.path) == false else {
            throw WorkbenchError.message("拖拽未使用当前应用的文件引用")
        }
        rejected = false
        do { _ = try store.draggedFileReferences(Data(UUID().uuidString.utf8)) } catch { rejected = true }
        guard rejected else { throw WorkbenchError.message("伪造拖拽引用未拒绝") }
    }
    private static func checkDropGuards(store: AppStore, model: FileModel, source: URL) async throws {
        let directory = model.path
        var available = true
        let target = FileTransferTarget(model: model, store: store, isAvailable: { available })
        let count = store.transfers.count
        guard !target.receiveDrop([]) else { throw WorkbenchError.message("空拖拽未拒绝") }
        for reason in 0..<3 {
            model.errorMessage = nil
            let provider = try store.fileDragProvider([FileEndpoint(path: source.path)])
            guard target.receiveDrop([provider]) else { throw WorkbenchError.message("无法开始异步拖拽回归") }
            if reason == 0 { model.path = directory + "/changed" }
            if reason == 1 { available = false }
            if reason == 2 { model.busy = true }
            try await wait { model.errorMessage != nil }
            guard store.transfers.count == count else { throw WorkbenchError.message("目标变化后仍然入队复制") }
            model.path = directory; model.busy = false; available = true
        }
        var host = HostProfile(name: "drop target fixture", address: "old.invalid")
        store.hosts.append(host)
        defer { store.hosts.removeAll { $0.id == host.id } }
        let remote = FileModel(host: host, store: store); remote.path = "/tmp"
        let remoteTarget = FileTransferTarget(model: remote, store: store, isAvailable: { true })
        let provider = try store.fileDragProvider([FileEndpoint(path: source.path)])
        guard remoteTarget.receiveDrop([provider]) else { throw WorkbenchError.message("无法开始主机变更回归") }
        host.address = "changed.invalid"; store.hosts[store.hosts.count - 1] = host
        try await wait { remote.errorMessage != nil }
        guard store.transfers.count == count else { throw WorkbenchError.message("目标主机改变后仍然入队") }
        var rejected = 0
        let endpoint = FileEndpoint(hostID: remote.host!.id, path: source.path)
        do { _ = try remoteTarget.snapshot() } catch { rejected += 1 }
        do { try store.copyFileReferences([endpoint], sourceHost: remote.host) } catch { rejected += 1 }
        do { _ = try store.fileDragProvider([endpoint], sourceHost: remote.host) } catch { rejected += 1 }
        guard rejected == 3 else { throw WorkbenchError.message("旧终端主机配置被当作新主机复制") }
        func fileProvider(_ url: URL) -> NSItemProvider {
            let provider = NSItemProvider(); let data = url.dataRepresentation
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in completion(data, nil); return nil }
            return provider
        }
        model.errorMessage = nil
        guard target.receiveDrop([fileProvider(source), fileProvider(URL(string: "https://invalid.example/file")!)]) else { throw WorkbenchError.message("无法开始混合拖入回归") }
        try await wait { model.errorMessage != nil }
        guard store.transfers.count == count else { throw WorkbenchError.message("无效混合拖入产生了部分任务") }
        let folder = source.deletingLastPathComponent().appendingPathComponent("拖入文件夹")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let nested = folder.appendingPathComponent("nested.txt"); let contents = Data("provider-batch".utf8)
        try contents.write(to: nested)
        let single = source.deletingLastPathComponent().appendingPathComponent("拖入文件.txt")
        try contents.write(to: single)
        model.errorMessage = nil
        guard target.receiveDrop([fileProvider(folder), fileProvider(single)]) else { throw WorkbenchError.message("Finder 批量拖入未接受") }
        try await wait { store.transfers.count == count + 2 && store.activeCount == 0 }
        guard try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("拖入文件夹/nested.txt")) == contents,
              try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(single.lastPathComponent)) == contents,
              FileManager.default.fileExists(atPath: nested.path) else { throw WorkbenchError.message("Finder 文件和目录拖入内容不一致或删除源文件") }
        let tokenFile = source.deletingLastPathComponent().appendingPathComponent("token-once.txt")
        try contents.write(to: tokenFile)
        let token = try store.fileDragProvider([FileEndpoint(path: tokenFile.path)])
        guard target.receiveDrop([token]) else { throw WorkbenchError.message("内部拖拽未接受") }
        try await wait { store.transfers.count == count + 3 && store.activeCount == 0 }
        guard store.draggedFiles == nil else { throw WorkbenchError.message("拖拽令牌未消费") }
        model.errorMessage = nil
        guard target.receiveDrop([token]) else { throw WorkbenchError.message("无法开始令牌重放回归") }
        try await wait { model.errorMessage != nil }
        guard store.transfers.count == count + 3 else { throw WorkbenchError.message("已消费拖拽令牌重复入队") }
        model.errorMessage = nil
        print("PASS · 异步拖入拒绝目录变化/不可见分栏/忙碌/主机修改/混合无效URL/令牌重放，Finder文件与目录批量复制")
    }
    static func runUI(workspace: Workspace, output: URL) async throws {
        let store = workspace.store; let transport = store.transport
        let hosts = store.hosts.filter { $0.address == "127.0.0.1" && [22281, 22282].contains($0.port) }
        if ProcessInfo.processInfo.environment["SWB_QA_REQUIRE_SSH"] == "1", hosts.count < 2 { throw WorkbenchError.message("跨主机回归需要两个隔离 SSH 主机") }
        let root = store.paths.root.appendingPathComponent("file-pane-ui")
        let first = root.appendingPathComponent("source"); let second = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let file = first.appendingPathComponent("跨栏 文件.txt"); let bytes = Data("file-pane-keyboard".utf8)
        try bytes.write(to: file)
        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            workspace.filePanes.forEach { $0.stop() }
            board.clearContents()
            if let previous { board.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        workspace.browseFiles(.local)
        guard let original = workspace.currentFileBrowser else { throw WorkbenchError.message("未创建文件分栏") }
        original.load(first.path)
        try await wait { !original.busy && original.tableView?.window != nil }
        guard let window = original.tableView?.window else { throw WorkbenchError.message("文件列表没有窗口") }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait { NSApp.isActive && window.isKeyWindow }
        original.selection = [file.path]
        try await shortcut("c", code: 8, table: original.tableView!)
        guard store.fileClipboard == [FileEndpoint(path: file.path)] else { throw WorkbenchError.message("原生⌘C没有复制选中文件") }
        workspace.splitFilePane()
        guard let destination = workspace.currentFileBrowser else { throw WorkbenchError.message("未创建目标分栏") }
        destination.load(second.path)
        try await wait {
            !destination.busy && destination.tableView?.window != nil && destination.tableView !== original.tableView
                && destination.tableView?.numberOfRows == destination.visibleFiles.count
                && original.tableView?.numberOfRows == original.visibleFiles.count
        }
        var expectedSort = FileSort()
        for zoomed in [false, true] {
            if zoomed { workspace.togglePaneZoom(); try await Task.sleep(for: .milliseconds(180)) }
            for _ in 0..<3 {
                expectedSort.cycle(.name)
                try await clickHeader(destination.tableView!)
                try await wait { destination.fileSort == expectedSort || original.fileSort.column != nil }
                guard original.fileSort.column == nil, destination.fileSort == expectedSort else { throw WorkbenchError.message("目标栏排序改变了源栏或未正确切换，zoomed=\(zoomed)，source=\(original.fileSort.description)，destination=\(destination.fileSort.description)") }
            }
        }
        workspace.togglePaneZoom(); try await Task.sleep(for: .milliseconds(180))
        guard destination.fileSort.column == nil else { throw WorkbenchError.message("目标栏排序未按升序/降序/默认循环") }
        guard !original.previewBusy, !destination.previewBusy else { throw WorkbenchError.message("收起预览后仍读取选中文件") }
        try await shortcut("v", code: 9, table: destination.tableView!)
        try await wait { store.activeCount == 0 }
        guard try Data(contentsOf: second.appendingPathComponent(file.lastPathComponent)) == bytes,
              original.path == first.path else { throw WorkbenchError.message("⌘V没有复制到目标分栏，或改变了源目录") }
        let dragged = first.appendingPathComponent("dragged.txt")
        let secondDragged = first.appendingPathComponent("dragged-second.txt")
        try bytes.write(to: dragged)
        try bytes.write(to: secondDragged)
        original.load()
        try await wait { !original.busy && original.files.contains(where: { $0.path == secondDragged.path }) }
        let provider = try await rowDragProvider(model: original, paths: [dragged.path, secondDragged.path])
        try drop(provider, on: destination, workspace: workspace)
        try await wait { store.activeCount == 0 && FileManager.default.fileExists(atPath: second.appendingPathComponent("dragged-second.txt").path) }
        guard try Data(contentsOf: second.appendingPathComponent("dragged.txt")) == bytes,
              try Data(contentsOf: second.appendingPathComponent("dragged-second.txt")) == bytes,
              FileManager.default.fileExists(atPath: dragged.path) else { throw WorkbenchError.message("拖拽接收链未复制文件或删除了源文件") }
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        window.contentView?.addSubview(input); input.stringValue = ""
        board.clearContents(); board.setString("input-only", forType: .string)
        window.makeFirstResponder(input)
        let count = store.transfers.count
        try await key("v", code: 9, window: window)
        guard input.stringValue == "input-only", store.transfers.count == count else { throw WorkbenchError.message("文本框粘贴被文件快捷键劫持") }
        input.removeFromSuperview()
        for _ in 0..<3 {
            workspace.focusFilePane(workspace.filePanes[0].id)
            workspace.splitFilePane(axis: .topBottom)
            guard let temporary = workspace.currentFileBrowser else { throw WorkbenchError.message("上下分栏未创建") }
            try await wait { !temporary.busy && temporary.tableView?.window != nil && window.firstResponder === temporary.tableView }
            workspace.closeFilePane(workspace.fileLayout.focused!)
        }
        try await wait { !original.busy }
        guard original.path == first.path else { throw WorkbenchError.message("反复分栏改变了源目录") }
        if hosts.count == 2 {
            let remoteDirectory = "/tmp/farport-file-panes-" + UUID().uuidString
            for host in hosts {
                try await Task.detached { let client = try transport.files(host); defer { client.close() }; try client.mkdir(remoteDirectory) }.value
            }
            defer { for host in hosts { let client = try? transport.files(host); try? client?.removeRecursively(remoteDirectory); client?.close() } }
            try await wait { !original.busy && original.files.contains(where: { $0.path == file.path }) }
            original.selection = [file.path]
            try await shortcut("c", code: 8, table: original.tableView!)
            workspace.fileSource = .host(hosts[0].id)
            let remoteSource = workspace.currentFileBrowser!
            remoteSource.load(remoteDirectory)
            try await wait { !remoteSource.busy && remoteSource.tableView?.window != nil && window.firstResponder === remoteSource.tableView }
            try await key("v", code: 9, window: window)
            try await wait { store.activeCount == 0 }
            let path = RemotePath.join(remoteDirectory, file.lastPathComponent)
            let copied = try await Task.detached { let client = try transport.files(hosts[0]); defer { client.close() }; return try client.preview(path) }.value
            guard copied == bytes else { throw WorkbenchError.message("切换主机后直接⌘V没有发送文件") }
            remoteSource.load()
            try await wait { !remoteSource.busy && remoteSource.files.contains(where: { $0.path == path }) }
            remoteSource.selection = [path]
            try await shortcut("c", code: 8, table: remoteSource.tableView!)
            guard store.fileClipboard == [FileEndpoint(hostID: hosts[0].id, path: path)] else { throw WorkbenchError.message("远端来源⌘C没有更新剪贴板：\(remoteSource.errorMessage ?? "无错误提示")") }
            let other = Workspace(store: store)
            other.browseFiles(.host(hosts[1].id))
            let remoteDestination = other.currentFileBrowser!
            remoteDestination.load(remoteDirectory)
            let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            otherWindow.contentView = NSHostingView(rootView: FilePaneWorkspace(workspace: other, store: store).focusedSceneObject(other))
            otherWindow.makeKeyAndOrderFront(nil)
            defer { other.filePanes.forEach { $0.stop() }; otherWindow.orderOut(nil) }
            try await wait { !remoteDestination.busy && remoteDestination.tableView?.window != nil }
            try await shortcut("v", code: 9, table: remoteDestination.tableView!)
            try await wait { store.activeCount == 0 && store.transfers.contains { $0.destination.hostID == hosts[1].id && $0.destination.path == path } }
            let received = try await Task.detached { let client = try transport.files(hosts[1]); defer { client.close() }; return try client.preview(path) }.value
            guard received == bytes else { throw WorkbenchError.message("跨窗口远端到远端⌘C/⌘V内容不一致") }
            let draggedPath = RemotePath.join(remoteDirectory, "cross-window-drag.txt")
            try await Task.detached {
                let client = try transport.files(hosts[0]); defer { client.close() }
                try client.createFile(draggedPath)
                try client.saveText(draggedPath, data: bytes, expected: client.stat(draggedPath), original: Data())
            }.value
            try await wait { !remoteDestination.busy }
            remoteSource.load()
            try await wait { !remoteSource.busy && remoteSource.files.contains(where: { $0.path == draggedPath }) }
            let remoteProvider = try await rowDragProvider(model: remoteSource, paths: [draggedPath])
            try drop(remoteProvider, on: remoteDestination, workspace: other)
            try await wait { store.activeCount == 0 && store.transfers.contains(where: { $0.destination.path == draggedPath && $0.status == .completed }) }
            let draggedContent = try await Task.detached { let client = try transport.files(hosts[1]); defer { client.close() }; return try client.preview(draggedPath) }.value
            guard draggedContent == bytes else { throw WorkbenchError.message("跨窗口远端拖拽内容不一致") }
            print("PASS · 切换主机后直接⌘V、本机→SSH、跨窗口SSH→SSH实际文件内容一致")
        }
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        print("PASS · 文件双栏真实⌘C/⌘V、拖拽provider接收链、目录独立、文本框粘贴不被劫持")
        print("NOTE · 鼠标拖拽手势尚需人工验收；provider接收链测试不代替系统拖拽验收")
        fflush(stdout)
    }
    private static func shortcut(_ character: String, code: UInt16, table: NSTableView) async throws {
        guard let window = table.window else { throw WorkbenchError.message("没有键盘目标窗口") }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(table)
        try await key(character, code: code, window: window)
    }
    private static func clickHeader(_ table: NSTableView) async throws {
        guard let header = table.headerView, let window = table.window else { throw WorkbenchError.message("没有文件表头") }
        let rectangle = header.headerRect(ofColumn: 0)
        let point = header.convert(NSPoint(x: rectangle.midX, y: rectangle.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw WorkbenchError.message("无法生成表头点击事件") }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(60))
        }
    }
    private static func drop(_ provider: NSItemProvider, on model: FileModel, workspace: Workspace) throws {
        let pane = workspace.filePanes.first { workspace.fileBrowser(in: $0) === model }
        let target = FileTransferTarget(model: model, store: workspace.store, isAvailable: {
            guard let pane else { return false }
            return workspace.page == .files && workspace.filePanes.contains { $0.id == pane.id }
                && workspace.fileBrowser(in: pane) === model
        })
        guard target.receiveDrop([provider]) else { throw WorkbenchError.message("文件拖拽接收链拒绝文件") }
    }
    private static func rowDragProvider(model: FileModel, paths: Set<String>) async throws -> NSItemProvider {
        model.selection = paths
        try await Task.sleep(for: .milliseconds(100))
        guard let table = model.tableView else { throw WorkbenchError.message("没有文件表格") }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let rows = IndexSet(model.visibleFiles.indices.filter { paths.contains(model.visibleFiles[$0].path) })
        let writers: [NSPasteboardWriting] = rows.compactMap { row in
            if let outline = table as? NSOutlineView, let item = outline.item(atRow: row) {
                return outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: item)
            }
            return table.dataSource?.tableView?(table, pasteboardWriterForRow: row)
        }
        guard writers.count == rows.count, pasteboard.writeObjects(writers), let data = pasteboard.data(forType: AppStore.filePasteboardType) else { throw WorkbenchError.message("文件行拖拽未提供文件引用") }
        return NSItemProvider(item: data as NSData, typeIdentifier: UTType.workbenchFiles.identifier)
    }
    private static func key(_ character: String, code: UInt16, window: NSWindow) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else { throw WorkbenchError.message("无法生成文件快捷键事件") }
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(180))
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() {
            guard Date() < deadline else { throw WorkbenchError.message("文件分栏回归超时：\(line)，active=\(NSApp.isActive)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
