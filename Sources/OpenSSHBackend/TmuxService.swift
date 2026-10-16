import Foundation
import WorkbenchCore

public struct TmuxTarget: Equatable, Sendable {
    public let paneID: String
    public let processID: String
    public let command: String
    public let directory: String
}

public struct TmuxService: Sendable {
    public let transport: SSHTransport
    public let host: HostProfile?
    public let socketName: String?
    public init(transport: SSHTransport, host: HostProfile?, socketName: String? = nil) { self.transport = transport; self.host = host; self.socketName = socketName }
    public static func localExecutable() throws -> String {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let executable = directories.map({ $0 + "/tmux" }).first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw WorkbenchError.message(L10n.text("本机未找到 tmux，安装后重试。不会自动修改 Shell 或 tmux 配置。"))
        }
        return executable
    }
    private var prefix: String {
        get throws { (host == nil ? RemotePath.quote(try Self.localExecutable()) : RemoteTmuxCommand.executableReference) + (socketName.map { " -L " + RemotePath.quote($0) } ?? "") }
    }
    public func execute(_ arguments: String, cancellation: CancellationFlag = CancellationFlag()) throws -> CommandResult { try runShell(prefix + " " + arguments, cancellation: cancellation) }
    private func runShell(_ command: String, cancellation: CancellationFlag) throws -> CommandResult {
        if let host {
            try transport.requirePosixShell(host, cancellation: cancellation)
            return try transport.run(host, command: RemoteTmuxCommand.wrap(command), cancellation: cancellation)
        }
        var environment = try LocalShellConfiguration().environment
        environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
        return try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", command], environment: environment, cancellation: cancellation)
    }
    public func sessions() throws -> [TmuxSession] {
        let result = try execute("list-sessions -F '#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}'")
        if result.status != 0, result.error.contains("no server running") || result.error.contains("no sessions") || (result.error.contains("error connecting to") && result.error.contains("No such file")) { return [] }
        _ = try result.checked()
        return result.text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { return nil }
            return TmuxSession(id: fields[0], name: fields[1], windows: Int(fields[2]) ?? 0, attached: Int(fields[3]) ?? 0, created: Date(timeIntervalSince1970: Double(fields[4]) ?? 0))
        }
    }
    public func panes() throws -> [TmuxPane] {
        let result = try execute("list-panes -a -F '#{pane_id}\t#{session_id}\t#{window_id}\t#{window_name}\t#{pane_index}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_active}'").checked()
        return result.text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 8 else { return nil }
            return TmuxPane(id: fields[0], sessionID: fields[1], windowID: fields[2], windowName: fields[3], index: fields[4], command: fields[5], directory: fields[6], active: fields[7] == "1")
        }
    }
    public func create(name: String) throws {
        try validateName(name)
        _ = try execute("new-session -d -s \(RemotePath.quote(name))").checked()
    }
    public func rename(session: String, name: String) throws {
        try validateName(name)
        _ = try execute("rename-session -t \(RemotePath.quote(session)) \(RemotePath.quote(name))").checked()
    }
    public func kill(session: String) throws { _ = try execute("kill-session -t \(RemotePath.quote(session))").checked() }
    public func createWindow(session: String) throws { _ = try execute("new-window -t \(RemotePath.quote(session))").checked() }
    public func mouseEnabled(session: String) throws -> Bool {
        try execute("show-options -v -t \(RemotePath.quote(session)) mouse").checked().text.trimmingCharacters(in: .whitespacesAndNewlines) == "on"
    }
    public func enableMouse(session: String) throws {
        _ = try execute("set-option -t \(RemotePath.quote(session)) mouse on").checked()
    }
    public func split(pane: String) throws { _ = try execute("split-window -h -t \(RemotePath.quote(pane))").checked() }
    public func select(pane: TmuxPane) throws {
        _ = try execute("select-window -t \(RemotePath.quote(pane.windowID)) \\; select-pane -t \(RemotePath.quote(pane.id))").checked()
    }
    public func target(session: String) throws -> TmuxTarget {
        let result = try execute("display-message -p -t \(RemotePath.quote(session)) '#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_in_mode}\t#{pane_dead}'").checked()
        let parts = result.text.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[4] == "0", parts[5] == "0" else { throw WorkbenchError.message(L10n.text("tmux 窗格处于复制模式、已退出或不可识别，未发送附件。")) }
        guard !["ssh", "mosh", "docker", "podman", "su", "sudo"].contains(parts[2]) else { throw WorkbenchError.message(L10n.text("窗格可能处于嵌套主机、容器或其他用户环境，请配置实际目标，不会自动发送附件。")) }
        return TmuxTarget(paneID: parts[0], processID: parts[1], command: parts[2], directory: parts[3])
    }
    public func paste(_ text: String, session: String, expected: TmuxTarget) throws {
        guard try target(session: session) == expected else { throw WorkbenchError.message(L10n.text("tmux 窗格或前台程序发生变化，附件未插入。")) }
        let buffer = "farport-" + UUID().uuidString
        let tmux = try prefix
        let fingerprint = [expected.paneID, expected.processID, expected.command, expected.directory, "0", "0"].joined(separator: "\t")
        let condition = "[ \"$(\(tmux) display-message -p -t \(RemotePath.quote(session)) '#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_in_mode}\t#{pane_dead}')\" = \(RemotePath.quote(fingerprint)) ]"
        let command = "printf %s \(RemotePath.quote(text)) | \(tmux) load-buffer -b \(RemotePath.quote(buffer)) - && \(condition) && \(tmux) paste-buffer -p -d -b \(RemotePath.quote(buffer)) -t \(RemotePath.quote(expected.paneID))"
        defer { _ = try? execute("delete-buffer -b \(RemotePath.quote(buffer))") }
        _ = try runShell(command, cancellation: CancellationFlag()).checked()
    }
    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 80, !name.contains(":"), !name.contains("."),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw WorkbenchError.message(L10n.text("tmux 会话名称限 1–80 个字符，不能包含句点、冒号或控制字符。")) }
    }
}
