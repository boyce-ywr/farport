import Foundation
import WorkbenchCore
import OpenSSHBackend

/// 终端路径链接打开的文件预览，记住来源终端以便关闭后归还焦点。
struct TerminalLinkPreview {
    let sessionID: UUID
    let model: FileModel
}

/// 解析结果：主机上的文件，以及（来自容器时）对应的容器内路径。
struct TerminalPathResolution: Sendable {
    let file: RemoteFile
    let containerPath: String?
}

/// 在终端所属主机上把 Cmd+点击的路径解析成真实存在的文件或目录。
/// 主机路径的基准依次为：tmux 窗格或本机前台进程所在目录、OSC 7 上报目录、主机 HOME。
/// 前台是 docker 时，路径按容器内 `-w`/WorkingDir 解析，再经 bind 挂载换算成主机路径，用同一套文件功能打开。
enum TerminalPathResolver {
    private static let containers = DockerPathContextCache()

    static func resolve(_ link: TerminalPathLink, transport: SSHTransport, host: HostProfile?, tmuxID: String?, shellPID: Int32, reportedDirectory: String?,
                        agentContainer: (binding: DockerAttachmentBinding, directory: String)?, cancellation: CancellationFlag) throws -> TerminalPathResolution {
        var hostBases: [String] = []
        var container: (context: DockerPathContext, bases: [String], home: String?)?
        if let agentContainer {
            let binding = agentContainer.binding
            let context = try containers.value("agent|" + binding.container.id + "|" + binding.container.started) {
                try binding.daemon.pathContext(binding.container.id, cancellation: cancellation)
            }
            container = (context, [agentContainer.directory, context.workingDirectory], ContainerPath.home(user: binding.user))
        } else if let tmuxID {
            // 不复用附件的窗格校验：复制模式（回滚查看输出）下也要能点击路径。
            let service = TmuxService(transport: transport, host: host)
            let format = "#{pane_current_command}\t#{pane_current_path}"
            let fields = try service.execute("display-message -p -t \(RemotePath.quote(tmuxID)) \(RemotePath.quote(format))", cancellation: cancellation, timeout: 10)
                .checked().text.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
            guard fields.count == 2 else { throw WorkbenchError.message(L10n.text("无法读取 tmux 窗格的当前目录。")) }
            try rejectRemoteShell(fields[0])
            if TerminalDirectory.validPath(fields[1]) { hostBases.append(fields[1]) }
            if fields[0] == "docker" {
                let terminal: LocalDockerTerminal
                do { terminal = try host == nil ? service.localDockerTerminal(session: tmuxID) : service.remoteDockerTerminal(session: tmuxID, cancellation: cancellation) }
                catch { throw WorkbenchError.message(L10n.text("无法识别 tmux 窗格中的 Docker 容器（窗格处于复制模式时请先退出）：") + error.localizedDescription) }
                container = try dockerContainer(terminal, transport: transport, cancellation: cancellation)
            }
        } else if host == nil {
            if let directory = LocalProcessDirectory.current(shellPID: shellPID) { hostBases.append(directory) }
            else if let terminal = try? LocalDockerTerminal.local(shellPID: shellPID) { container = try dockerContainer(terminal, transport: transport, cancellation: cancellation) }
            else if let name = LocalProcessDirectory.foregroundName(shellPID: shellPID) { try rejectRemoteShell(name) }
        }
        // OSC 7 由主机 Shell 上报；前台在容器里时它不代表容器内目录。
        if container == nil, let reportedDirectory { hostBases.append(reportedDirectory) }
        let client = try transport.files(host, cancellation: cancellation); defer { client.close() }

        var candidates: [(host: String, container: String?)] = []
        var containerOnly: [String] = []
        if let container {
            let bases = container.bases.filter { $0.hasPrefix("/") }
            for path in link.candidates(home: container.home, bases: bases) {
                if let mapped = ContainerPath.hostPath(for: path, mounts: container.context.mounts) { candidates.append((mapped, ContainerPath.normalized(path))) }
                else { containerOnly.append(path) }
            }
            // 兜底：相对路径再按 docker 客户端在主机上的目录查找。
            if link.isRelative { for path in link.candidates(home: nil, bases: hostBases) where !candidates.contains(where: { $0.host == path }) { candidates.append((path, nil)) } }
        } else {
            // SFTP 的初始目录就是远端用户 HOME。
            let home = host == nil ? NSHomeDirectory() : try? client.realpath(".")
            for path in link.candidates(home: home, bases: hostBases + [home].compactMap { $0 }) { candidates.append((path, nil)) }
        }
        for candidate in candidates {
            try cancellation.check()
            guard let attributes = try? client.stat(candidate.host, followLinks: true) else { continue }
            // 本机 realpath 只接受目录：文件规范化其父目录再拼文件名，去掉 ./ 与 ..，与文件列表里的路径一致。
            let path = attributes.isDirectory ? ((try? client.realpath(candidate.host)) ?? candidate.host)
                : ((try? client.realpath(RemotePath.parent(candidate.host))).map { RemotePath.join($0, (candidate.host as NSString).lastPathComponent) } ?? candidate.host)
            return TerminalPathResolution(file: RemoteFile(name: (path as NSString).lastPathComponent, path: path, attributes: attributes), containerPath: candidate.container)
        }
        if candidates.isEmpty, let first = containerOnly.first {
            throw WorkbenchError.message(L10n.text("该路径只存在于容器内（命名卷或容器文件系统），无法用文件功能打开：") + first)
        }
        throw WorkbenchError.message(L10n.text("未在目标主机上找到该路径：") + (link.variants.first ?? ""))
    }

    /// 前台为 ssh/mosh 时路径属于第三台主机；sudo、su 仍是同一文件系统，按主机路径处理。
    private static func rejectRemoteShell(_ command: String) throws {
        guard ["ssh", "mosh"].contains(command) else { return }
        throw WorkbenchError.message(L10n.text("终端前台正在通过 SSH 连接其他主机，路径不属于此主机，未打开。"))
    }

    private static func dockerContainer(_ terminal: LocalDockerTerminal, transport: SSHTransport, cancellation: CancellationFlag) throws -> (context: DockerPathContext, bases: [String], home: String?) {
        // 同一 docker 客户端进程连着同一容器，挂载不变；进程或容器变化时键随之变化。
        let key = [terminal.host?.id.uuidString ?? "local", terminal.target.paneID, String(terminal.foregroundPID), terminal.remoteStarted,
                   "\(terminal.startedSeconds).\(terminal.startedMicroseconds)"].joined(separator: "|")
        let context: DockerPathContext
        do {
            context = try containers.value(key) {
                let selection = try DockerAttachmentDaemon.discover(terminal: terminal, transport: transport, cancellation: cancellation)
                return try selection.daemon.pathContext(selection.detectedContainerID, cancellation: cancellation)
            }
        } catch { throw WorkbenchError.message(L10n.text("无法读取终端中 Docker 容器的挂载信息：") + error.localizedDescription) }
        let user = terminal.invocation.user ?? context.user
        return (context, [terminal.invocation.workdir, context.workingDirectory].compactMap { $0 }, ContainerPath.home(user: user))
    }
}

/// 容器挂载信息缓存，最多保留 32 项。
private final class DockerPathContextCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(key: String, value: DockerPathContext)] = []
    func value(_ key: String, load: () throws -> DockerPathContext) throws -> DockerPathContext {
        if let cached = lock.withLock({ entries.first { $0.key == key }?.value }) { return cached }
        let value = try load()
        lock.withLock { entries.removeAll { $0.key == key }; entries.append((key, value)); if entries.count > 32 { entries.removeFirst() } }
        return value
    }
}
