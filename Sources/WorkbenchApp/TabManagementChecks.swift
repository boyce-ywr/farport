import AppKit
import Foundation
import WorkbenchCore

@MainActor
enum TabManagementChecks {
    static func run(workspace: Workspace) async throws {
        for _ in 0..<12 { workspace.connectLocal() }
        guard let first = workspace.layout.tabs.first, let last = workspace.layout.tabs.last else { throw WorkbenchError.message("未创建标签") }
        let selected = workspace.selectedTerminalID; let identities = workspace.sessions.map(\.id)
        guard workspace.reorderTab(payload: "\(workspace.tabDragScope.uuidString):\(first.id.uuidString)", onto: last.id), workspace.layout.tabs.last?.id == first.id else { throw WorkbenchError.message("向后拖动不能移动至末尾") }
        guard workspace.selectedTerminalID == selected && workspace.sessions.map(\.id) == identities else { throw WorkbenchError.message("排序改变焦点或会话身份") }
        let before = workspace.layout
        guard !workspace.reorderTab(payload: "\(UUID().uuidString):\(first.id.uuidString)", onto: last.id), workspace.layout == before else { throw WorkbenchError.message("跨窗口拖拽不能污染会话组") }
        workspace.chooseTerminalTab(first.id)
        workspace.newTerminal(split: true)
        let group = workspace.layout.selectedTab!
        workspace.reorderTab(payload: "\(workspace.tabDragScope.uuidString):\(group.id.uuidString)", onto: workspace.layout.tabs[0].id)
        guard workspace.layout.tabs.first == group else { throw WorkbenchError.message("多分栏标签排序改变布局") }
        let splitSession = workspace.selectedTerminalID!
        let layoutBeforeFileMove = workspace.layout
        workspace.reorderFileTab(splitSession, onto: workspace.orderedFileSessions[0].id)
        guard workspace.orderedFileSessions.first?.id == splitSession, workspace.layout == layoutBeforeFileMove else { throw WorkbenchError.message("文件来源中的分栏会话排序改变了终端分组") }
        let deadline = Date().addingTimeInterval(20)
        while workspace.sessions.contains(where: { !$0.connected }) {
            guard Date() < deadline else { throw WorkbenchError.message("多终端启动超时") }; try await Task.sleep(for: .milliseconds(100))
        }
        print("PASS · 12 个标签拖放数据处理、前后排序、跨窗口拒绝、多分栏与焦点/会话身份保留")
    }
}
