import AppKit
import WorkbenchCore
import OpenSSHBackend

/// macOS 远端经 SSH 同步剪贴板：用回环 SSH（模拟远端 Mac）实测 pbcopy / pbpaste 往返（含中文），以及目标判断。
/// 不连接 VNC 服务（需要用户的 macOS 账号口令）；结束后恢复本机剪贴板。
@MainActor
enum RemoteDesktopClipboardChecks {
    static func run(workspace: Workspace) async throws {
        let store = workspace.store
        guard let host = store.hosts.first(where: { $0.address == "127.0.0.1" && $0.port == 22 }) else { throw WorkbenchError.message("需要回环 SSH 主机") }
        func expect(_ condition: Bool, _ message: String) throws { if !condition { throw WorkbenchError.message(message) } }
        try expect(RemoteDesktopSession.desktopIsSSHHost(endpoint: try ScreenSharingEndpoint(host: "127.0.0.1"), host: host), "SSH 承载的本机回环桌面应走 SSH 剪贴板")
        try expect(RemoteDesktopSession.desktopIsSSHHost(endpoint: try ScreenSharingEndpoint(host: "localhost"), host: host), "localhost 应视为 SSH 主机")
        var named = host; named.address = "mac-mini"
        try expect(RemoteDesktopSession.desktopIsSSHHost(endpoint: try ScreenSharingEndpoint(host: "MAC-MINI"), host: named), "直连主机地址本身应视为 SSH 主机")
        try expect(!RemoteDesktopSession.desktopIsSSHHost(endpoint: try ScreenSharingEndpoint(host: "192.168.1.50"), host: host), "经 SSH 转到其他机器的桌面不能用 SSH 剪贴板")

        let board = NSPasteboard.general
        let previous = board.string(forType: .string)
        defer { board.clearContents(); if let previous { board.setString(previous, forType: .string) } }
        let transport = store.transport
        let outgoing = "Farport 剪贴板 ✓ \(UUID().uuidString.prefix(6))\n第二行"
        let push = try await Task.detached { try transport.run(host, command: RemoteDesktopSession.sshClipboardCommand("pbcopy"), input: Data(outgoing.utf8), cancellation: CancellationFlag(), timeout: 15, outputLimit: 4096) }.value
        try expect(push.status == 0, "SSH pbcopy 失败（\(push.status)）：\(push.error)")
        try await Task.sleep(for: .milliseconds(300))
        try expect(board.string(forType: .string) == outgoing, "SSH 写入后图形会话剪贴板内容不一致")
        let incoming = "远端复制 ✓ \(UUID().uuidString.prefix(6))"
        board.clearContents(); board.setString(incoming, forType: .string)
        let pull = try await Task.detached { try transport.run(host, command: RemoteDesktopSession.sshClipboardCommand("pbpaste"), input: nil, cancellation: CancellationFlag(), timeout: 15, outputLimit: 1024 * 1024 + 1) }.value
        try expect(pull.status == 0 && String(data: pull.output, encoding: .utf8) == incoming, "SSH pbpaste 读回不一致（\(pull.status)）")
        print("PASS · macOS 远端经 SSH 同步剪贴板：pbcopy 写入、pbpaste 读回（含中文与换行），屏幕登录用户核对通过；桌面目标判断正确")
    }
}
