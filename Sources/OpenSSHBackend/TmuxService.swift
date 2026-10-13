import Foundation
import WorkbenchCore

public struct TmuxService: Sendable {
    public let transport: SSHTransport
    public let host: HostProfile
    public init(transport: SSHTransport, host: HostProfile) { self.transport = transport; self.host = host }
    public func sessions() throws -> [TmuxSession] {
        let result = try transport.run(host, command: "command -v tmux >/dev/null 2>&1 || { printf '未安装 tmux，请在远端自行安装后重试。' >&2; exit 127; }; tmux list-sessions -F '#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}'")
        if result.status != 0, result.error.contains("no server running") || result.error.contains("no sessions") || (result.error.contains("error connecting to") && result.error.contains("No such file")) { return [] }
        _ = try result.checked()
        return result.text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { return nil }
            return TmuxSession(id: fields[0], name: fields[1], windows: Int(fields[2]) ?? 0, attached: Int(fields[3]) ?? 0, created: Date(timeIntervalSince1970: Double(fields[4]) ?? 0))
        }
    }
    public func panes() throws -> [TmuxPane] {
        let result = try transport.run(host, command: "tmux list-panes -a -F '#{pane_id}\t#{session_id}\t#{window_id}\t#{window_name}\t#{pane_index}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_active}'").checked()
        return result.text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 8 else { return nil }
            return TmuxPane(id: fields[0], sessionID: fields[1], windowID: fields[2], windowName: fields[3], index: fields[4], command: fields[5], directory: fields[6], active: fields[7] == "1")
        }
    }
    public func create(name: String) throws {
        try validateName(name)
        _ = try transport.run(host, command: "tmux new-session -d -s \(RemotePath.quote(name))").checked()
    }
    public func rename(session: String, name: String) throws {
        try validateName(name)
        _ = try transport.run(host, command: "tmux rename-session -t \(RemotePath.quote(session)) \(RemotePath.quote(name))").checked()
    }
    public func kill(session: String) throws { _ = try transport.run(host, command: "tmux kill-session -t \(RemotePath.quote(session))").checked() }
    public func createWindow(session: String) throws { _ = try transport.run(host, command: "tmux new-window -t \(RemotePath.quote(session))").checked() }
    public func split(pane: String) throws { _ = try transport.run(host, command: "tmux split-window -h -t \(RemotePath.quote(pane))").checked() }
    public func select(pane: TmuxPane) throws {
        _ = try transport.run(host, command: "tmux select-window -t \(RemotePath.quote(pane.windowID)) && tmux select-pane -t \(RemotePath.quote(pane.id))").checked()
    }
    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 80, !name.contains(":"), !name.contains("."),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw WorkbenchError.message("tmux 会话名称限 1–80 个字符，不能包含句点、冒号或控制字符。") }
    }
}
