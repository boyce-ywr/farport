import Foundation
import WorkbenchCore

/// herdr 当前聚焦窗格的进程信息（来自 `pane list` 与 `pane process-info`）。
public struct HerdrFocusedPane: Equatable, Sendable {
    public let paneID: String
    public let shellPID: Int32
    /// 前台进程名，例如 ["docker"]。
    public let foreground: [String]
}

extension MultiplexerService {
    /// herdr 会话当前聚焦的窗格。多个客户端同时附着时，聚焦窗格由 herdr 服务端决定。
    public func herdrFocusedPane(session: String, cancellation: CancellationFlag = CancellationFlag()) throws -> HerdrFocusedPane {
        func unavailable() -> Error { WorkbenchError.message(L10n.text("无法确认 herdr 当前窗格，未发送附件。")) }
        guard kind == .herdr else { throw unavailable() }
        let exe = Self.executableReference, name = RemotePath.quote(session)
        let marker = "__FARPORT_HERDR_\(UUID().uuidString)__"
        // 一次往返读取窗格列表，再按聚焦窗格读取进程信息。
        let script = """
        panes=$(\(exe) --session \(name) pane list) || exit 4
        printf '%s\\n' "$panes"
        pane=$(printf '%s' "$panes" | tr '{' '\\n' | grep '"focused":true' | grep -o '"pane_id":"[^"]*"' | head -1 | cut -d'"' -f4)
        [ -n "$pane" ] || exit 5
        printf '\\n%s\\n' \(marker)
        \(exe) --session \(name) pane process-info --pane "$pane"
        """
        let output = try run(script, cancellation: cancellation, timeout: 15).checked().text
        let parts = output.components(separatedBy: "\n" + marker + "\n")
        guard parts.count == 2 else { throw unavailable() }
        return try Self.parseFocusedPane(panes: parts[0], process: parts[1])
    }
    static func parseFocusedPane(panes: String, process: String) throws -> HerdrFocusedPane {
        func unavailable() -> Error { WorkbenchError.message(L10n.text("无法确认 herdr 当前窗格，未发送附件。")) }
        func result(_ text: String) -> [String: Any]? {
            guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return root["result"] as? [String: Any]
        }
        let focused = ((result(panes)?["panes"] as? [[String: Any]]) ?? []).filter { $0["focused"] as? Bool == true }
        guard focused.count == 1, let paneID = focused[0]["pane_id"] as? String,
              let info = result(process)?["process_info"] as? [String: Any], info["pane_id"] as? String == paneID,
              let shell = (info["shell_pid"] as? NSNumber)?.int32Value, shell > 0 else { throw unavailable() }
        let names = ((info["foreground_processes"] as? [[String: Any]]) ?? []).compactMap { item -> String? in
            ((item["name"] as? String) ?? (item["argv0"] as? String)).map { ($0 as NSString).lastPathComponent }
        }
        return HerdrFocusedPane(paneID: paneID, shellPID: shell, foreground: names)
    }

    /// herdr 聚焦窗格前台是 docker 时识别其容器；不是 docker 时返回 nil（按普通附着主机处理）。
    /// 读取前后核对聚焦窗格及其 Shell 未变化。target.paneID 为 herdr 窗格 ID，processID 为窗格 Shell PID。
    public func herdrDockerTerminal(session: String, cancellation: CancellationFlag = CancellationFlag()) throws -> LocalDockerTerminal? {
        let pane = try herdrFocusedPane(session: session, cancellation: cancellation)
        guard pane.foreground.contains("docker") else { return nil }
        let target = TmuxTarget(paneID: pane.paneID, processID: String(pane.shellPID), command: "docker", directory: "")
        guard let host else {
            func unavailable() -> Error { WorkbenchError.message(L10n.text("无法确认 herdr 窗格的 Docker 进程，未发送附件。")) }
            return try LocalDockerTerminal.inspect(target: target, panePID: pane.shellPID, unavailable: unavailable) {
                try herdrFocusedPane(session: session, cancellation: cancellation) == pane
            }
        }
        func unavailable() -> Error { WorkbenchError.message(L10n.text("无法确认远端 herdr 窗格的 Docker 进程，未发送附件。")) }
        let script = "pane=\(pane.shellPID)\n" + LocalDockerTerminal.remoteForegroundProbe + "\n" + LocalDockerTerminal.remoteForegroundOutput
        try transport.requirePosixShell(host, cancellation: cancellation)
        let result = try transport.run(host, command: "/bin/sh -c " + RemotePath.quote(script), cancellation: cancellation, timeout: 15)
        guard result.status == 0 else { throw unavailable() }
        let terminal = try LocalDockerTerminal.remote(target: target, lines: result.text.components(separatedBy: "\n")[...], host: host, transport: transport, cancellation: cancellation, unavailable: unavailable)
        guard try herdrFocusedPane(session: session, cancellation: cancellation) == pane else { throw unavailable() }
        return terminal
    }
}
