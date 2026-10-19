import Foundation
import WorkbenchCore

func checkWorkspaceTools() throws {
    let first = UUID(); let second = UUID(); let remote = UUID()
    var layout = TerminalLayout(); layout.select(first); layout.split(with: second, axis: .topBottom)
    layout.resize(layout.selectedTab!.root.id, ratio: 0.7)
    layout.toggleZoom()
    let snapshot = WorkspaceSnapshot(id: UUID(), title: "本机与开发机", terminals: [
        SavedTerminal(id: first, hostID: nil, connectionKey: nil, tmuxID: nil),
        SavedTerminal(id: second, hostID: remote, connectionKey: "test-host", tmuxID: "existing-session")
    ], layout: layout)
    try snapshot.validate()
    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
    try expect(decoded.layout == layout && decoded.terminals == snapshot.terminals, "恢复记录保留分屏比例、焦点、tmux身份")
    var broken = snapshot; broken.terminals.removeLast()
    try rejects("拒绝布局引用不存在的终端") { try broken.validate() }
    broken = snapshot; broken.terminals.append(broken.terminals[0])
    try rejects("拒绝重复终端标识") { try broken.validate() }
    try CommandSnippet(name: "查看日志", command: "tail -n 100 '/tmp/日志.txt'", tags: "日志", hostID: remote).validate()
    for command in ["echo ok\nwhoami", "echo ok\r", "\u{1b}[200~echo test", "\u{0}", "", "echo\u{2028}test"] {
        try rejects("片段禁止换行、控制字符及空内容") { try CommandSnippet(name: "test", command: command).validate() }
    }
    try rejects("片段名称不能为空") { try CommandSnippet(command: "pwd").validate() }
    try rejects("片段限制长度") { try CommandSnippet(name: "test", command: String(repeating: "a", count: 16385)).validate() }
    let allowed: Set<String> = ["dev.example", "127.0.0.1"]
    try expect(TerminalDirectory.path(from: "file://DEV.EXAMPLE/tmp/a%20b/%E4%B8%AD%E6%96%87", allowedHosts: allowed) == "/tmp/a b/中文", "目录报告正确解码空格中文并核对主机")
    for report in ["file://other.example/tmp", "file://user@dev.example/tmp", "file://dev.example:22/tmp", "file://dev.example/tmp?x=1", "file://dev.example/tmp#hash", "file://dev.example/tmp/%00", "file://dev.example/tmp/%0A", "https://dev.example/tmp", "/tmp", "file:///tmp"] {
        try expect(TerminalDirectory.path(from: report, allowedHosts: allowed) == nil, "拒绝无效目录报告：\(report)")
    }
    var tools = WorkspaceToolsState(); tools.workspaces = [snapshot]; tools.snippets = [CommandSnippet(name: "test", command: "pwd")]
    tools.bookmarks = [DirectoryBookmark(hostID: remote, connectionKey: "test-host", path: "/tmp/a b")]
    let restored = try JSONDecoder().decode(WorkspaceToolsState.self, from: JSONEncoder().encode(tools))
    try expect(restored.workspaces == tools.workspaces && restored.snippets == tools.snippets && restored.bookmarks == tools.bookmarks, "工具记录独立持久化")
    var manyLayout = TerminalLayout(); var manyTerminals: [SavedTerminal] = []
    for _ in 0..<65 {
        let identifier = UUID(); manyLayout.select(identifier)
        manyTerminals.append(SavedTerminal(id: identifier, hostID: nil, connectionKey: nil, tmuxID: nil))
    }
    try WorkspaceSnapshot(id: UUID(), title: "many", terminals: manyTerminals, layout: manyLayout).validate()
}
