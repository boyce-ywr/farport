import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum WindowsSSHChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        guard workspace.store.isTestWorkspace, ProcessInfo.processInfo.environment["SWB_QA_WINDOWS_READONLY"] == "1", workspace.store.hosts.count == 1, let host = workspace.host else { throw WorkbenchError.message("Windows 检查需要独立主机配置与只读标记") }
        let transport = workspace.store.transport
        let detected = try await Task.detached { try HostMonitorService(transport: transport, host: host).detect(cancellation: CancellationFlag()) }.value
        guard detected == .windows else { throw WorkbenchError.message("目标不是 Windows，已停止") }
        let connection = try await Task.detached { try transport.testConnection(host) }.value
        guard connection.sftpAvailable else { throw WorkbenchError.message("Windows SFTP 未通过") }
        let failure = try await Task.detached { try transport.run(host, command: "true") }.value
        guard failure.status != 0, !failure.error.contains("�"), failure.error.contains("true") else { throw WorkbenchError.message("Windows 原始错误仍未正确解码") }
        let model = TmuxModel(host: host, store: workspace.store)
        await model.refresh()
        guard model.errorMessage == L10n.text("当前 SSH 使用 Windows 原生 Shell，不能直接管理 tmux。请打开普通终端；如需 tmux，请连接已配置的 Linux 或 WSL SSH 服务。") else { throw WorkbenchError.message("Windows tmux 未显示明确的能力说明") }
        workspace.connect(host)
        guard let session = workspace.selectedTerminal else { throw WorkbenchError.message("Windows 终端未创建") }
        defer { workspace.close(session) }
        try await wait { session.connected && session.terminal.process.running }
        let marker = "FARPORT_WINDOWS_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        session.terminal.send(txt: "echo \(marker)\r")
        try await wait { hasLine(marker, session: session) }
        session.terminal.send(txt: "echo 中文输入输出验证\r")
        try await wait { hasLine("中文输入输出验证", session: session) }
        print("PASS · Windows 真机：连接探测、SFTP、原生终端实际命令与中文输入输出、CP936 错误、tmux 能力说明；未改远端配置")
        if let content = session.terminal.window?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        workspace.page = .tmux
        try await Task.sleep(for: .milliseconds(800))
        if let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.deletingPathExtension().appendingPathExtension("tmux.png"))
        }
    }
    private static func hasLine(_ value: String, session: TerminalSession) -> Bool {
        let screen = session.terminal.getTerminal()
        return (0..<screen.rows).contains { screen.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).trimmingCharacters(in: .whitespacesAndNewlines) == value }
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("Windows 终端回归超时：\(line)") }; try await Task.sleep(for: .milliseconds(100)) }
    }
}
