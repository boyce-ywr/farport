import Foundation
import WorkbenchCore

/// Zellij 与 herdr 的会话层服务（列出、窗格、新建、重命名、结束、进入命令）；tmux 只用其安装检测，会话操作仍走 `TmuxService`。
/// 本机与远端共用同一段 POSIX Shell：先发现可执行文件，再执行命令；找不到时退出码 127。
public struct MultiplexerService: Sendable {
    public enum Availability: Equatable, Sendable {
        case missing
        case outdated(String)
        case available(String)
    }
    public let kind: MultiplexerKind
    public let transport: SSHTransport
    public let host: HostProfile?
    public init(kind: MultiplexerKind, transport: SSHTransport, host: HostProfile?) {
        self.kind = kind; self.transport = transport; self.host = host
    }

    public static let executableReference = "\"$farport_mux_executable\""
    /// 发现可执行文件的 Shell 片段。非登录 exec 通道的 PATH 通常不含 Homebrew、~/.local/bin 与 ~/.cargo/bin，这里追加而不前置，已有 PATH 优先。
    public static func script(_ kind: MultiplexerKind, _ command: String) -> String {
        let name = kind.executableName
        return """
        PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$HOME/.local/bin:$HOME/.cargo/bin"; export PATH
        farport_mux_executable=$(command -v \(name) 2>/dev/null || :)
        case "$farport_mux_executable" in /*) ;; *) farport_mux_executable= ;; esac
        if [ -z "$farport_mux_executable" ] || [ ! -x "$farport_mux_executable" ]; then
            printf '%s\\n' 'Farport: 未找到可执行的 \(name)；已检查 PATH、Homebrew、~/.local/bin 与 ~/.cargo/bin。' >&2
            exit 127
        fi
        \(command)
        """
    }
    public static func wrap(_ kind: MultiplexerKind, _ command: String) -> String { "/bin/sh -c " + RemotePath.quote(script(kind, command)) }
    /// 终端标签中执行的附着命令（不含 `/bin/sh -c`）。
    public static func attachScript(_ attachment: MultiplexerAttachment) -> String {
        let name = RemotePath.quote(attachment.session), exe = executableReference
        switch (attachment.kind, attachment.create) {
        case (.zellij, false): return script(.zellij, "exec \(exe) attach \(name)")
        case (.zellij, true): return script(.zellij, "exec \(exe) attach -c \(name)")
        case (.herdr, false): return script(.herdr, "exec \(exe) session attach \(name)")
        case (.herdr, true): return script(.herdr, "exec \(exe) --session \(name)")
        case (.tmux, _): return script(.tmux, "exec \(exe) attach-session -t \(name)")
        }
    }
    /// 本机终端与命令不继承外层多路复用器的环境变量，避免工具误判为嵌套会话。
    public static func isolatedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in !(key == "TMUX" || key == "TMUX_PANE" || key.hasPrefix("ZELLIJ") || key.hasPrefix("HERDR_")) }
    }

    func run(_ command: String, cancellation: CancellationFlag, timeout: TimeInterval = 20) throws -> CommandResult {
        if let host {
            try transport.requirePosixShell(host, cancellation: cancellation)
            return try transport.run(host, command: Self.wrap(kind, command), cancellation: cancellation, timeout: timeout)
        }
        let configuration = try LocalShellConfiguration()
        return try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", Self.script(kind, command)], environment: Self.isolatedEnvironment(configuration.environment),
                                     cancellation: cancellation, timeout: timeout, currentDirectory: URL(fileURLWithPath: NSHomeDirectory()))
    }

    public func availability(cancellation: CancellationFlag = CancellationFlag()) throws -> Availability {
        let result = try run("\(Self.executableReference) " + (kind == .tmux ? "-V" : "--version"), cancellation: cancellation, timeout: 15)
        if result.status == 127 { return .missing }
        let text = try result.checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = MultiplexerKind.parseVersion(text) else { return .outdated(text) }
        let label = "\(version.0).\(version.1)"
        return kind.supports(version: version) ? .available(text) : .outdated(label)
    }

    public func sessions(cancellation: CancellationFlag = CancellationFlag()) throws -> [MultiplexerSession] {
        let exe = Self.executableReference
        switch kind {
        case .zellij:
            let result = try run("\(exe) list-sessions -n", cancellation: cancellation)
            if result.status != 0, (result.text + result.error).contains("No active zellij sessions") { return [] }
            return MultiplexerParsing.zellijSessions(try result.checked().text)
        case .herdr:
            return MultiplexerParsing.herdrSessions(try run("\(exe) session list --json", cancellation: cancellation).checked().text)
        case .tmux: return []
        }
    }

    /// 一次往返读取所有运行中会话的窗格；单个会话读取失败时该会话无窗格，不影响其他会话。
    public func panes(of sessions: [MultiplexerSession], cancellation: CancellationFlag = CancellationFlag()) throws -> [MultiplexerPane] {
        let running = sessions.filter(\.running)
        guard !running.isEmpty else { return [] }
        let exe = Self.executableReference
        let marker = "__FARPORT_MUX_\(UUID().uuidString)__"
        let commands = running.enumerated().map { index, session -> String in
            let name = RemotePath.quote(session.name)
            switch kind {
            case .zellij: return "printf '\\n%s %s\\n' \(marker) \(index); \(exe) --session \(name) action list-panes --json 2>/dev/null"
            default: return "printf '\\n%s %s\\n' \(marker) \(index); \(exe) --session \(name) workspace list 2>/dev/null; printf '\\n%s-\\n' \(marker); \(exe) --session \(name) pane list 2>/dev/null"
            }
        }.joined(separator: "; ")
        let output = try run(commands + "; :", cancellation: cancellation, timeout: 30).checked().text
        var result: [MultiplexerPane] = []
        for chunk in output.components(separatedBy: "\n" + marker + " ").dropFirst() {
            guard let newline = chunk.firstIndex(of: "\n"), let index = Int(chunk[..<newline]), running.indices.contains(index) else { continue }
            let body = String(chunk[chunk.index(after: newline)...]), session = running[index].name
            if kind == .zellij { result += MultiplexerParsing.zellijPanes(body, session: session) }
            else {
                let parts = body.components(separatedBy: "\n" + marker + "-\n")
                if parts.count == 2 { result += MultiplexerParsing.herdrPanes(workspaces: parts[0], panes: parts[1], session: session) ?? [] }
            }
        }
        return result
    }

    /// Zellij 可后台创建；herdr 没有可靠的后台创建方式，由终端标签执行 `herdr --session` 创建。
    public var createsInBackground: Bool { kind == .zellij }
    public func createDetached(name: String, cancellation: CancellationFlag = CancellationFlag()) throws -> MultiplexerSession {
        try kind.validateSessionName(name)
        guard createsInBackground else { throw WorkbenchError.message(L10n.text("\(kind.title) 需在终端中创建会话。")) }
        guard try !sessions(cancellation: cancellation).contains(where: { $0.name == name }) else { throw WorkbenchError.message(L10n.text("已存在同名会话，请换一个名称。")) }
        _ = try run("\(Self.executableReference) attach -b \(RemotePath.quote(name))", cancellation: cancellation).checked()
        guard let session = try sessions(cancellation: cancellation).first(where: { $0.name == name && $0.running }) else {
            throw WorkbenchError.message(L10n.text("新建的 \(kind.title) 会话已不可用，请刷新后重试。"))
        }
        return session
    }
    public func rename(session: String, to name: String, cancellation: CancellationFlag = CancellationFlag()) throws {
        guard kind.canRename else { throw WorkbenchError.message(L10n.text("herdr 不支持重命名会话。")) }
        try kind.validateSessionName(name)
        guard try !sessions(cancellation: cancellation).contains(where: { $0.name == name }) else { throw WorkbenchError.message(L10n.text("已存在同名会话，请换一个名称。")) }
        _ = try run("\(Self.executableReference) --session \(RemotePath.quote(session)) action rename-session \(RemotePath.quote(name))", cancellation: cancellation).checked()
    }
    /// 结束并删除会话：运行中的会话会终止其中全部进程；已退出的只删除记录。
    public func kill(session: MultiplexerSession, cancellation: CancellationFlag = CancellationFlag()) throws {
        let exe = Self.executableReference, name = RemotePath.quote(session.name)
        switch kind {
        case .zellij:
            _ = try run("\(exe) delete-session --force \(name)", cancellation: cancellation).checked()
        case .herdr:
            if session.running { _ = try run("\(exe) session stop \(name) --json", cancellation: cancellation).checked() }
            _ = try run("\(exe) session delete \(name) --json", cancellation: cancellation).checked()
        case .tmux: break
        }
        if try sessions(cancellation: cancellation).contains(where: { $0.name == session.name }) {
            throw WorkbenchError.message(L10n.text("\(kind.title) 会话仍然存在，请刷新后确认。"))
        }
    }
}
