import Foundation
import WorkbenchCore
import OpenSSHBackend

/// 终端路径链接打开的文件预览，记住来源终端以便关闭后归还焦点。
struct TerminalLinkPreview {
    let sessionID: UUID
    let model: FileModel
}

/// 在终端所属主机上把 Cmd+点击的路径解析成真实存在的文件或目录。
/// 相对路径的基准依次为：tmux 窗格或本机前台进程的当前目录、OSC 7 上报目录、目标主机 HOME。
enum TerminalPathResolver {
    private static let nestedCommands: Set<String> = ["ssh", "mosh", "docker", "podman", "su", "sudo"]

    static func resolve(_ link: TerminalPathLink, transport: SSHTransport, host: HostProfile?, tmuxID: String?, shellPID: Int32,
                        reportedDirectory: String?, cancellation: CancellationFlag) throws -> RemoteFile {
        var bases: [String] = []
        if let tmuxID {
            // 不复用附件的窗格校验：复制模式（回滚查看输出）下也要能点击路径。
            let format = "#{pane_current_command}\t#{pane_current_path}"
            let fields = try TmuxService(transport: transport, host: host)
                .execute("display-message -p -t \(RemotePath.quote(tmuxID)) \(RemotePath.quote(format))", cancellation: cancellation, timeout: 10)
                .checked().text.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
            guard fields.count == 2 else { throw WorkbenchError.message(L10n.text("无法读取 tmux 窗格的当前目录。")) }
            guard !nestedCommands.contains(fields[0]) else { throw WorkbenchError.message(L10n.text("tmux 窗格正在运行 SSH、容器或其他用户环境，路径不属于此主机，未打开。")) }
            if TerminalDirectory.validPath(fields[1]) { bases.append(fields[1]) }
        } else if host == nil {
            // 前台为 ssh、docker、sudo 等时返回 nil：路径属于别的主机或容器，不能按本机文件打开。
            guard let directory = LocalProcessDirectory.current(shellPID: shellPID) else {
                throw WorkbenchError.message(L10n.text("此终端前台正在运行 SSH、容器或其他用户环境，路径不属于此 Mac，未打开。"))
            }
            bases.append(directory)
        }
        if let reportedDirectory { bases.append(reportedDirectory) }
        let client = try transport.files(host, cancellation: cancellation); defer { client.close() }
        // SFTP 的初始目录就是远端用户 HOME。
        let home = host == nil ? NSHomeDirectory() : try? client.realpath(".")
        if let home { bases.append(home) }
        for candidate in link.candidates(home: home, bases: bases) {
            try cancellation.check()
            guard let attributes = try? client.stat(candidate, followLinks: true) else { continue }
            // 本机 realpath 只接受目录：文件规范化其父目录再拼文件名，去掉 ./ 与 ..，与文件列表里的路径一致。
            let path = attributes.isDirectory ? ((try? client.realpath(candidate)) ?? candidate)
                : ((try? client.realpath(RemotePath.parent(candidate))).map { RemotePath.join($0, (candidate as NSString).lastPathComponent) } ?? candidate)
            return RemoteFile(name: (path as NSString).lastPathComponent, path: path, attributes: attributes)
        }
        throw WorkbenchError.message(L10n.text("未在目标主机上找到该路径：") + (link.variants.first ?? ""))
    }
}
