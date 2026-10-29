import Foundation
import Darwin
import WorkbenchCore

public struct LocalDockerTerminal: Equatable, Sendable {
    public let target: TmuxTarget
    public let foregroundPID: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public let executable: String
    public let invocation: DockerTerminalCommand
    public let environment: [String: String]
    /// 远端 tmux 窗格中的 docker 客户端：所在 SSH 主机与 ps 报告的启动时间；本机为 nil 与空串。
    public var host: HostProfile? = nil
    public var remoteStarted = ""
}

extension TmuxService {
    public func dockerTerminal(session: String, cancellation: CancellationFlag = CancellationFlag()) throws -> LocalDockerTerminal {
        host == nil ? try localDockerTerminal(session: session) : try remoteDockerTerminal(session: session, cancellation: cancellation)
    }
    public func localDockerTerminal(session: String) throws -> LocalDockerTerminal {
        func unavailable() -> Error { WorkbenchError.message(L10n.text("无法确认原 tmux 窗格的 Docker 进程，未发送附件。")) }
        guard host == nil else { throw unavailable() }
        let target = try attachmentTarget(session: session)
        guard target.command == "docker" else { throw unavailable() }
        guard let panePID = Int32(target.processID), panePID > 0 else { throw unavailable() }
        func foreground() throws -> Int32 {
            var pane = proc_bsdinfo()
            guard proc_pidinfo(panePID, PROC_PIDTBSDINFO, 0, &pane, Int32(MemoryLayout.size(ofValue: pane))) == MemoryLayout.size(ofValue: pane),
                  pane.pbi_uid == getuid() else { throw unavailable() }
            return Int32(bitPattern: pane.e_tpgid)
        }
        let identifier = try foreground()
        guard identifier > 0 else { throw unavailable() }
        var info = proc_bsdinfo()
        guard proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info), info.pbi_uid == getuid() else { throw unavailable() }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(identifier, &path, UInt32(path.count)) > 0 else { throw unavailable() }
        let executable = String(cString: path)
        guard (executable as NSString).lastPathComponent == "docker" else { throw unavailable() }
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, identifier]
        var length = 0
        guard sysctl(&query, UInt32(query.count), nil, &length, nil, 0) == 0, length > 4, length <= 1024 * 1024 else { throw unavailable() }
        var data = [UInt8](repeating: 0, count: length)
        guard sysctl(&query, UInt32(query.count), &data, &length, nil, 0) == 0 else { throw unavailable() }
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 1024 else { throw unavailable() }
        var position = 4
        while position < length && data[position] != 0 { position += 1 }
        while position < length && data[position] == 0 { position += 1 }
        func next() throws -> String {
            let start = position
            while position < length && data[position] != 0 { position += 1 }
            guard position < length, let value = String(bytes: data[start..<position], encoding: .utf8) else { throw unavailable() }
            position += 1; return value
        }
        var arguments: [String] = []
        for _ in 0..<count { arguments.append(try next()) }
        var environment: [String: String] = [:]
        while position < length && data[position] != 0 {
            let value = try next()
            guard let separator = value.firstIndex(of: "=") else { continue }
            let key = String(value[..<separator])
            if ["DOCKER_CONTEXT", "DOCKER_HOST", "DOCKER_CONFIG"].contains(key) { environment[key] = String(value[value.index(after: separator)...]) }
        }
        var finalInfo = proc_bsdinfo()
        guard try attachmentTarget(session: session) == target, try foreground() == identifier,
              proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, &finalInfo, Int32(MemoryLayout.size(ofValue: finalInfo))) == MemoryLayout.size(ofValue: finalInfo),
              finalInfo.pbi_uid == info.pbi_uid, finalInfo.pbi_start_tvsec == info.pbi_start_tvsec, finalInfo.pbi_start_tvusec == info.pbi_start_tvusec else { throw unavailable() }
        return LocalDockerTerminal(target: target, foregroundPID: identifier, startedSeconds: info.pbi_start_tvsec,
                                   startedMicroseconds: info.pbi_start_tvusec, executable: executable,
                                   invocation: try DockerTerminalCommand(arguments: arguments), environment: environment)
    }
}

extension TmuxService {
    /// 远端窗格前台进程探测（一次 SSH）：前后两次核对 tmux 窗格；Linux 读 /proc，macOS 用 ps。参数无法解析时，仅在只有一个运行中容器时使用它。
    private func remoteDockerProbe(session: String) throws -> String {
        let tmux = try prefix
        return """
        farport_format='#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_in_mode}\t#{pane_dead}'
        before=$(\(tmux) display-message -p -t \(RemotePath.quote(session)) "$farport_format") || exit 4
        pane=$(printf '%s\\n' "$before" | cut -f2)
        fg=$(ps -o tpgid= -p "$pane" 2>/dev/null | tr -d ' ')
        case $fg in ''|*[!0-9]*|0) exit 3;; esac
        [ "$(ps -o uid= -p "$fg" | tr -d ' ')" = "$(id -u)" ] || exit 3
        started=$(ps -o lstart= -p "$fg" | tr -s ' ')
        if [ -r "/proc/$fg/cmdline" ]; then
          exe=$(readlink "/proc/$fg/exe" 2>/dev/null || :); mode=nul
          args=$(base64 < "/proc/$fg/cmdline" | tr -d '\\n')
          environment=$( (tr '\\0' '\\n' < "/proc/$fg/environ" | grep -E '^DOCKER_(HOST|CONTEXT|CONFIG)=' | base64 | tr -d '\\n') 2>/dev/null || :)
        else
          exe=$(ps -o comm= -p "$fg"); mode=space
          args=$(ps -ww -o args= -p "$fg" | base64 | tr -d '\\n')
          environment=
        fi
        \(RemoteDockerHost.path)
        case $exe in /*) ;; *) exe=$(command -v "${exe##*/}" 2>/dev/null || :);; esac
        [ "$(\(tmux) display-message -p -t \(RemotePath.quote(session)) "$farport_format")" = "$before" ] || exit 5
        printf '%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n' "$before" "$fg" "$started" "$exe" "$mode" "$args" "$environment"
        """
    }
    public func remoteDockerTerminal(session: String, cancellation: CancellationFlag = CancellationFlag()) throws -> LocalDockerTerminal {
        func unavailable() -> Error { WorkbenchError.message(L10n.text("无法确认远端 tmux 窗格的 Docker 进程，未发送附件。")) }
        guard let host else { throw unavailable() }
        let result = try runShell(try remoteDockerProbe(session: session), cancellation: cancellation, timeout: 15)
        let lines = result.text.components(separatedBy: "\n")
        guard result.status == 0, lines.count >= 7 else { throw unavailable() }
        let pane = lines[0].components(separatedBy: "\t")
        guard pane.count == 6, pane[2] == "docker", pane[4] == "0", pane[5] == "0", let identifier = Int32(lines[1]), identifier > 0, lines[3].hasPrefix("/"),
              (lines[3] as NSString).lastPathComponent == "docker", let raw = Data(base64Encoded: lines[5]),
              let text = String(data: raw, encoding: .utf8) else { throw unavailable() }
        let target = TmuxTarget(paneID: pane[0], processID: pane[1], command: pane[2], directory: pane[3])
        let arguments = lines[4] == "nul" ? text.split(separator: "\0").map(String.init) : text.split(whereSeparator: \.isWhitespace).map(String.init)
        var environment: [String: String] = [:]
        for line in (Data(base64Encoded: lines[6]).flatMap { String(data: $0, encoding: .utf8) } ?? "").split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        let invocation: DockerTerminalCommand
        if let parsed = try? DockerTerminalCommand(arguments: arguments) { invocation = parsed }
        else if case let containers = try transport.run(host, command: "/bin/sh -c " + RemotePath.quote(RemoteDockerHost.path + "; exec " + RemotePath.quote(lines[3]) + " ps -q --no-trunc"), cancellation: cancellation, timeout: 15).checked().text.split(separator: "\n").map(String.init), containers.count == 1 { invocation = try DockerTerminalCommand(arguments: ["docker", "exec", "-it", containers[0]]) }
        else { throw WorkbenchError.message(L10n.text("无法从远端窗格的 docker 命令识别目标容器，且运行中的容器不止一个，未发送附件。")) }
        return LocalDockerTerminal(target: target, foregroundPID: identifier, startedSeconds: 0, startedMicroseconds: 0, executable: lines[3],
                                   invocation: invocation, environment: environment, host: host, remoteStarted: lines[2])
    }
}
