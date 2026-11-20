import AppKit
import WorkbenchCore

/// 侧栏主机手动排序：同组调整后侧栏按新顺序显示、hosts.json 保存新顺序，不同分组互不影响。只使用隔离测试工作区里的假主机。
@MainActor
enum HostOrderChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let store = workspace.store
        guard store.isTestWorkspace else { throw WorkbenchError.message("主机排序检查只允许在隔离测试工作区运行") }
        let names = ["mac-mini", "sh-linux(dev)", "my-phone", "sh-win", "my-linux"]
        for (index, name) in names.enumerated() {
            try store.saveHost(HostProfile(name: name, address: "192.0.2.\(index + 1)", group: "我的主机"))
        }
        try store.saveHost(HostProfile(name: "other-group", address: "192.0.2.99", group: "其他"))
        func order(_ group: String) -> [String] { store.hosts.filter { $0.group == group }.map(\.name) }
        func saved() throws -> [String] { try store.paths.load([HostProfile].self, from: store.paths.hosts).filter { $0.group == "我的主机" }.map(\.name) }
        func id(_ name: String) -> UUID { store.hosts.first { $0.name == name }!.id }

        store.moveHost(id("my-linux"), .top)
        guard order("我的主机") == ["my-linux", "mac-mini", "sh-linux(dev)", "my-phone", "sh-win"], try saved() == order("我的主机") else { throw WorkbenchError.message("移到最前未生效或未保存：\(order("我的主机"))") }
        store.moveHost(id("mac-mini"), .down)
        guard order("我的主机") == ["my-linux", "sh-linux(dev)", "mac-mini", "my-phone", "sh-win"] else { throw WorkbenchError.message("下移未生效：\(order("我的主机"))") }
        store.moveHost(id("sh-win"), to: id("sh-linux(dev)"))
        guard order("我的主机") == ["my-linux", "sh-win", "sh-linux(dev)", "mac-mini", "my-phone"], try saved() == order("我的主机") else { throw WorkbenchError.message("拖放未生效或未保存：\(order("我的主机"))") }
        store.moveHost(id("other-group"), to: id("my-linux"))
        guard order("我的主机").count == 5, order("其他") == ["other-group"] else { throw WorkbenchError.message("跨分组拖放不应生效") }
        // 重新编辑主机不改变其位置。
        var edited = store.hosts.first { $0.name == "mac-mini" }!; edited.port = 2222
        try store.saveHost(edited)
        guard order("我的主机") == ["my-linux", "sh-win", "sh-linux(dev)", "mac-mini", "my-phone"] else { throw WorkbenchError.message("编辑主机改变了顺序") }
        print("PASS · 侧栏主机：移到最前、下移、同组拖放即时生效并写入 hosts.json；跨分组不移动；编辑主机不改变位置")
        workspace.page = .terminal
        try await Task.sleep(for: .seconds(2))
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let content = window.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
    }
}
