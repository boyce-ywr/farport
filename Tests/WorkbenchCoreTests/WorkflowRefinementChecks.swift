import Foundation
import WorkbenchCore

func checkWorkflowRefinements() throws {
    let host = HostProfile(name: "fixture", address: "host.example")
    let service = ForwardedService(hostID: host.id, connectionKey: host.connectionKey, name: "Web", target: "127.0.0.1", port: 8080, path: "/目录 a")
    try service.validate()
    let url = try service.localURL(port: 19001)
    try expect(url.host == "127.0.0.1" && url.port == 19001 && url.path == "/目录 a" && url.query == nil && url.user == nil, "服务入口固定回环地址并正确编码路径")
    for path in ["https://example.com", "/lab?token=secret", "/#password", "/\n"] {
        var invalid = service; invalid.path = path
        try rejects("服务模板拒绝完整URL、令牌和控制字符") { try invalid.validate() }
    }
    for scheme in ["file", "javascript", "vnc"] { var invalid = service; invalid.scheme = scheme; try rejects("服务模板仅接受HTTP协议") { try invalid.validate() } }
    var invalidPort = service; invalidPort.port = 0
    try rejects("拒绝无效服务端口") { try invalidPort.validate() }
    let oldTools = Data("{\"workspaces\":[],\"snippets\":[],\"bookmarks\":[]}".utf8)
    try expect(try JSONDecoder().decode(WorkspaceToolsState.self, from: oldTools).services == nil, "旧工具记录缺少服务字段仍可读取")
    let change = TextChangePreview(original: "same\nold\ntail", edited: "same\nnew\ntail")
    try expect(change.firstLine == 2 && change.removed == "old" && change.added == "new" && !change.truncated, "差异截取公共前后缀之间的真实替换区域")
    try expect(TextChangePreview(original: "same", edited: "same").isEmpty, "相同内容不产生变更")
    try expect(TextChangePreview(original: "", edited: "新内容").added == "新内容", "空文件新增内容")
    try expect(TextChangePreview(original: "旧内容", edited: "").removed == "旧内容", "完整删除内容")
    let large = TextChangePreview(original: (0..<501).map { "old \($0)" }.joined(separator: "\n"), edited: "new")
    try expect(large.truncated && large.removedCount == 501 && large.removed.components(separatedBy: "\n").count == 200, "大差异保留准确范围计数但限制预览行数")
    let original = Data("original".utf8); let edited = Data("edited".utf8)
    let draft = EditorDraft(hostID: host.id, connectionKey: host.connectionKey, path: "/test", original: original, edited: edited)
    try expect(draft.canRestore(hostID: host.id, connectionKey: host.connectionKey, path: "/test", current: original), "草稿仅匹配原始版本时可恢复")
    try expect(!draft.canRestore(hostID: host.id, connectionKey: host.connectionKey, path: "/test", current: edited), "远端变化时拒绝自动套用草稿")
    try expect(!draft.canRestore(hostID: UUID(), connectionKey: host.connectionKey, path: "/test", current: original), "草稿不会串主机")
    try expect(!draft.canRestore(hostID: host.id, connectionKey: "changed", path: "/test", current: original), "草稿不会串连接身份")
    try expect(!EditorDraft(hostID: nil, connectionKey: nil, path: "/test", original: Data([255]), edited: edited).isValid, "无效编码草稿不可恢复")
    let sequence = Array("\u{1b}]133;A\u{7}提示符😀\u{1b}]133;B\u{1b}\\echo test\r\n\u{1b}]133;C\u{7}output\u{1b}]133;D;0\u{7}".utf8)
    let expected: [ShellMarkerAction] = [.prompt, .input, .begin, .end(0)]
    for split in 0...sequence.count {
        var stream = ShellMarkerStream()
        let first = stream.scan(Array(sequence[..<split])); let second = stream.scan(Array(sequence[split...]))
        try expect((first + second).map(\.action) == expected, "任意跨包切分均识别相同Shell标记，包括UTF8和ST终止符")
    }
    var byteStream = ShellMarkerStream(); var actions: [ShellMarkerAction] = []
    for byte in sequence { actions += byteStream.scan([byte]).map(\.action) }
    try expect(actions == expected, "逐字节传输保留语义标记顺序")
    var markers = ShellMarkerStream()
    let hidden = Array("\u{1b}Pfake\u{1b}]133;A\u{7}\u{1b}\\".utf8)
    try expect(!markers.scan(hidden).contains { $0.action == .prompt }, "DCS内部伪标记不能产生有效命令")
    markers = ShellMarkerStream()
    try expect(markers.scan(Array("\u{1b}[2J".utf8)).map(\.action) == [.invalidate], "清屏立即废弃命令边界")
    markers = ShellMarkerStream()
    try expect(markers.scan(Array(("\u{1b}]133;" + String(repeating: "x", count: 1024) + "\u{7}").utf8)).map(\.action) == [.invalidate], "超长语义标记拒绝且不无限缓存")
    markers = ShellMarkerStream()
    try expect(markers.scan(Array(("\u{1b}]52;c;" + String(repeating: "a", count: 4096) + "\u{7}").utf8)).isEmpty, "长OSC52不被误判成命令事件")
}
