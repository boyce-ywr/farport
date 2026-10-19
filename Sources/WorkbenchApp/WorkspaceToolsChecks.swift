import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum WorkspaceToolsChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let store = workspace.store
        let directory = store.paths.root.appendingPathComponent("命令与目录 test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = directory.appendingPathComponent("command-result")
        workspace.connectLocal()
        guard let first = workspace.selectedTerminal else { throw WorkbenchError.message("未创建测试终端") }
        try await wait { first.connected }
        first.terminal.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(800))
        let snippet = CommandSnippet(name: "验证不自动执行", command: "printf '%s' verified > \(RemotePath.quote(result.path))", tags: "测试")
        let clipboard = NSPasteboard.general.string(forType: .string)
        try workspace.insertSnippet(snippet, targetID: first.id, connectionID: first.connectionID)
        try await Task.sleep(for: .milliseconds(300))
        guard !FileManager.default.fileExists(atPath: result.path), NSPasteboard.general.string(forType: .string) == clipboard else {
            throw WorkbenchError.message("插入命令提前执行或更改了剪贴板")
        }
        first.terminal.process.send(data: Array("\r".utf8)[...])
        try await wait { FileManager.default.fileExists(atPath: result.path) }
        guard try String(contentsOf: result, encoding: .utf8) == "verified" else { throw WorkbenchError.message("插入的命令内容不正确") }
        first.terminal.feed(text: "\u{1b}[?1049h")
        do {
            try workspace.insertSnippet(snippet, targetID: first.id, connectionID: first.connectionID)
            throw WorkbenchError.message("未阻止向全屏程序插入命令")
        } catch WorkbenchError.message(let message) where message == L10n.text("请先退出全屏终端程序，确认位于 Shell 提示符后再插入命令。") {}
        first.terminal.feed(text: "\u{1b}[?1049l")
        workspace.connectLocal(split: true, axis: .topBottom)
        try await wait { workspace.selectedTerminal?.connected == true }
        do {
            try workspace.insertSnippet(snippet, targetID: first.id, connectionID: first.connectionID)
            throw WorkbenchError.message("切换目标后仍可插入旧命令")
        } catch WorkbenchError.message(let message) where message == L10n.text("目标终端已变化、断开或不符合适用主机；请重新打开命令面板。") {}
        workspace.layout.resize(workspace.layout.selectedTab!.root.id, ratio: 0.64)
        guard let snapshot = store.workspaceTools.workspaces.first(where: { $0.id == workspace.savedWorkspaceID }) else { throw WorkbenchError.message("工作区未自动保存") }
        store.workspaceTools.snippets = [snippet]
        guard store.flushWorkspaceTools() else { throw WorkbenchError.message("工作工具落盘失败") }
        let reopened = try AppStore()
        guard reopened.workspaceTools.snippets == [snippet], let persisted = reopened.workspaceTools.workspaces.first(where: { $0.id == snapshot.id }) else { throw WorkbenchError.message("重开应用丢失工具记录") }
        let toolsURL = store.paths.root.appendingPathComponent("workspace-tools.json")
        let savedTools = try Data(contentsOf: toolsURL)
        let invalidTools = Data("{".utf8)
        try invalidTools.write(to: toolsURL, options: .atomic)
        let unreadable = try AppStore()
        let refusedWrite = !unreadable.flushWorkspaceTools()
        let protected = try Data(contentsOf: toolsURL) == invalidTools && refusedWrite
        try savedTools.write(to: toolsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: toolsURL.path)
        guard protected else { throw WorkbenchError.message("损坏的工具记录被覆盖") }
        let restored = Workspace(store: reopened)
        restored.restoreWorkspace(persisted)
        guard restored.layout == snapshot.layout, restored.sessions.count == 2, restored.sessions.allSatisfy({ !$0.connected }) else { throw WorkbenchError.message("恢复丢失布局或提前启动未显示的终端") }
        let unknown = UUID()
        var missingLayout = TerminalLayout(); missingLayout.select(unknown)
        let missing = WorkspaceSnapshot(id: UUID(), title: "deleted", terminals: [SavedTerminal(id: unknown, hostID: UUID(), connectionKey: "missing", tmuxID: nil)], layout: missingLayout)
        let missingWorkspace = Workspace(store: reopened); missingWorkspace.restoreWorkspace(missing)
        guard missingWorkspace.sessions.isEmpty else { throw WorkbenchError.message("恢复了已移除的主机") }
        reopened.errorMessage = nil
        workspace.selectTerminal(first)
        let encodedPath = directory.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        first.terminal.feed(text: "\u{1b}]7;file://localhost\(encodedPath)\u{7}")
        try await wait { first.reportedDirectory == directory.path }
        workspace.openTerminalDirectory()
        try await wait { workspace.currentFileBrowser?.path == directory.path && workspace.currentFileBrowser?.busy == false }
        first.terminal.feed(text: "\u{1b}]7;file://unrelated.example/tmp\u{7}")
        try await wait { first.reportedDirectory == nil }
        guard workspace.currentFileBrowser?.path == directory.path else { throw WorkbenchError.message("跨主机目录报告改变了文件来源") }
        workspace.page = .terminal; workspace.showCommandSnippets = true
        try await Task.sleep(for: .milliseconds(600))
        try capture(output)
        workspace.showCommandSnippets = false
        try await Task.sleep(for: .milliseconds(400))
        let desktopHost = HostProfile(name: "测试 Mac", address: "mac.example", username: "tester")
        store.hosts.append(desktopHost); workspace.screenSharingHost = desktopHost
        try await Task.sleep(for: .milliseconds(600))
        try capture(output.deletingLastPathComponent().appendingPathComponent("desktop.png"))
        workspace.screenSharingHost = nil
        try await wait { !NSApp.windows.contains { $0.sheetParent != nil } }
        restored.sessions.forEach { $0.close() }; workspace.sessions.forEach { $0.close() }
        print("PASS · 原生PTY片段不自动执行/不改剪贴板/目标隔离、工作区持久化与恢复、真实OSC7目录联动、两个原生面板截图")
        fflush(stdout)
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw WorkbenchError.message("工作工具原生验收等待超时")
    }
    private static func capture(_ url: URL) throws {
        guard let view = NSApp.windows.first(where: { $0.sheetParent != nil })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw WorkbenchError.message("无法截取工作工具面板") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let composited = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: composited) else { throw WorkbenchError.message("无法创建面板截图背景") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor); context.cgContext.fill(bounds)
        if let image = bitmap.cgImage { context.cgContext.draw(image, in: bounds) }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = composited.representation(using: .png, properties: [:]) else { throw WorkbenchError.message("无法保存工作工具截图") }
        try data.write(to: url)
    }
}
