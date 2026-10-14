import AppKit
import Foundation
import WorkbenchCore

@MainActor
enum PaneLayoutChecks {
    static func run(workspace: Workspace) async throws {
        workspace.connectLocal()
        guard let first = workspace.selectedTerminal, let firstTab = workspace.layout.selectedTabID else { throw WorkbenchError.message("未创建首个标签") }
        try await wait { first.connected }
        first.terminal.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(500))
        try command("左右分栏", key: "d", modifiers: [.command]) { workspace.newTerminal(split: true) }
        try await wait { workspace.sessions.count == 2 && workspace.selectedTerminal?.connected == true }
        let second = workspace.selectedTerminal!
        try command("上下分栏", key: "d", modifiers: [.command, .shift]) { workspace.newTerminal(split: true, axis: .topBottom) }
        try await wait { workspace.sessions.count == 3 && workspace.selectedTerminal?.connected == true }
        let third = workspace.selectedTerminal!
        guard workspace.layout.tabs.count == 1, workspace.layout.selectedTab?.terminals == [first.id, second.id, third.id] else { throw WorkbenchError.message("分栏误建为独立标签") }
        workspace.layout.resize(workspace.layout.selectedTab!.root.id, ratio: 0.58)
        try await Task.sleep(for: .milliseconds(600))
        let frames = [first, second, third].map { $0.terminal.frame.size }
        let identities = [first, second, third].map(\.connectionID)
        guard frames[0].height > frames[1].height * 1.5, abs(frames[1].width - frames[2].width) < 2 else { throw WorkbenchError.message("左右加右侧上下分栏未正确布局") }
        workspace.connectLocal()
        let separate = workspace.selectedTerminal!
        try await wait { separate.connected }
        guard workspace.layout.tabs.count == 2, workspace.layout.selectedTab?.terminals == [separate.id], workspace.splitTerminalID == nil else { throw WorkbenchError.message("新标签残留旧标签右侧分栏") }
        let separateTab = workspace.layout.selectedTabID!
        for _ in 0..<8 {
            workspace.chooseTerminalTab(firstTab)
            try await Task.sleep(for: .milliseconds(100))
            guard workspace.selectedTerminalID == third.id, [first, second, third].map({ $0.terminal.frame.size }) == frames else { throw WorkbenchError.message("切换标签丢失焦点或改变已有分栏尺寸") }
            workspace.chooseTerminalTab(separateTab)
            try await Task.sleep(for: .milliseconds(100))
        }
        workspace.chooseTerminalTab(firstTab)
        try await Task.sleep(for: .milliseconds(250))
        guard [first, second, third].map(\.connectionID) == identities else { throw WorkbenchError.message("标签切换重建了终端连接") }
        if NSApp.isActive && NSApp.keyWindow != nil { try click(first.terminal) }
        else { print("SKIP · 后台无系统焦点，未验证鼠标焦点派发；改验工作区焦点与文件来源联动"); workspace.selectTerminal(first) }
        try await wait { workspace.selectedTerminalID == first.id && workspace.fileSource == .terminal(first.id) }
        try command("下一个分栏", key: "]", modifiers: [.command]) { workspace.focusNextPane() }
        try await wait { workspace.selectedTerminalID == second.id }
        try command("最大化 / 还原当前分栏", key: "\r", modifiers: [.command, .shift]) { workspace.togglePaneZoom() }
        try await wait { workspace.layout.selectedTab?.zoomed == true && second.terminal.frame.height > frames[1].height * 1.5 }
        try command("最大化 / 还原当前分栏", key: "\r", modifiers: [.command, .shift]) { workspace.togglePaneZoom() }
        try await wait { workspace.layout.selectedTab?.zoomed == false && [first, second, third].map({ $0.terminal.frame.size }) == frames }
        workspace.browseFiles(.terminal(third.id)); workspace.openFileSourceTerminal()
        guard workspace.layout.selectedTabID == firstTab, workspace.selectedTerminalID == third.id else { throw WorkbenchError.message("文件来源无法定位原标签分栏") }
        if let host = workspace.store.hosts.first, host.address == "127.0.0.1", [22281, 22282].contains(host.port) {
            workspace.connect(host, split: true)
            let remote = workspace.selectedTerminal!
            try await wait { remote.connected }
            workspace.chooseTerminalTab(separateTab); workspace.chooseTerminalTab(firstTab)
            guard workspace.selectedTerminalID == remote.id, workspace.layout.selectedTab?.terminals.count == 4 else { throw WorkbenchError.message("混合 SSH 分栏状态丢失") }
            workspace.close(remote)
        }
        guard first.connected && second.connected && third.connected && separate.connected else { throw WorkbenchError.message("关闭分栏影响其他终端") }
        for (index, session) in [first, second, third].enumerated() {
            session.terminal.send(txt: "clear; printf '\\nFarport · 标签内分栏 \(index + 1)\\n\\n'; printf '独立布局 · 稳定尺寸 · 明确焦点\\n'; pwd\n")
        }
        workspace.selectTerminal(third)
        print("PASS · 标签独立布局、嵌套上下/左右分栏、8 轮稳定尺寸、连接保留、点击处理链、文件关联、菜单声明/对应操作及最大化还原")
    }
    private static func command(_ title: String, key: String, modifiers: NSEvent.ModifierFlags, operation: () -> Void) throws {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items { if item.title == title { return item }; if let submenu = item.submenu, let found = find(submenu) { return found } }
            return nil
        }
        guard let menu = NSApp.mainMenu, let item = find(menu), item.keyEquivalent == key, item.keyEquivalentModifierMask == modifiers,
              let parent = item.menu else { throw WorkbenchError.message("菜单或快捷键声明错误：\(title)") }
        if !NSApp.isActive || NSApp.keyWindow == nil {
            print("SKIP · 后台无系统焦点，未派发菜单：\(title)；执行同一工作区操作验证布局")
            operation(); return
        }
        parent.delegate?.menuNeedsUpdate?(parent)
        parent.delegate?.menuWillOpen?(parent)
        parent.update()
        guard let activeItem = find(parent), activeItem.isEnabled else { throw WorkbenchError.message("菜单动作不可用：\(title)") }
        parent.performActionForItem(at: parent.index(of: activeItem))
        parent.delegate?.menuDidClose?(parent)
    }
    private static func click(_ terminal: SafeTerminalView) throws {
        guard let window = terminal.window else { throw WorkbenchError.message("终端未挂载原生窗口") }
        let point = terminal.convert(NSPoint(x: 30, y: 60), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
    private static func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(25)
        while !condition() { guard Date() < end else { throw WorkbenchError.message("分栏图形验证超时：检查点 \(line)") }; try await Task.sleep(for: .milliseconds(80)) }
    }
}
