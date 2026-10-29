import Foundation
import CryptoKit
import WorkbenchCore

public struct DockerContainer: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let user: String
    public let running: Bool
    public let paused: Bool
    public let restarting: Bool
    public let started: String
    public let restarts: Int
    public let terminal: Bool
    public let openInput: Bool
    public var displayName: String { name.hasPrefix("/") ? String(name.dropFirst()) : name }
}

public struct DockerAttachmentSelection: Identifiable, Sendable {
    public let id = UUID()
    public let daemon: DockerAttachmentDaemon
    public let terminal: LocalDockerTerminal
    public let containers: [DockerContainer]
    public let detectedContainerID: String
}

public struct DockerAttachmentBinding: Equatable, Sendable {
    public let daemon: DockerAttachmentDaemon
    public let container: DockerContainer
    public let terminal: LocalDockerTerminal
    public let user: String
    /// 绑定时 inspect（所选容器 + 原窗格容器引用）的原始输出，远端执行前在同一 shell 内比对。
    var fingerprint = ""
}

/// 远端 tmux 窗格中的 docker 客户端经 SSH 在原主机执行；比较时只看主机配置。
public struct RemoteDockerHost: Equatable, Sendable {
    let transport: SSHTransport
    let host: HostProfile
    static let path = "PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.docker/bin:$HOME/.orbstack/bin:/Applications/Docker.app/Contents/Resources/bin\"; export PATH"
    public static func == (left: Self, right: Self) -> Bool { left.host == right.host }
}

public struct DockerAttachmentDaemon: Equatable, Sendable {
    public let context: String
    public let endpoint: String
    public let identifier: String
    private let executable: String
    private let environment: [String: String]
    private let usesHost: Bool
    private let apiVersion: String
    private var remote: RemoteDockerHost? = nil
    private var connection: [String] {
        if remote == nil || usesHost { return endpoint.isEmpty ? [] : ["--host", endpoint] }
        return context.isEmpty ? [] : ["--context", context]
    }
    public var connectionDescription: String { usesHost ? "Unix socket · " + endpoint : context }
    private static let containerFormat = "{\"id\":{{json .Id}},\"name\":{{json .Name}},\"user\":{{json .Config.User}},\"running\":{{json .State.Running}},\"paused\":{{json .State.Paused}},\"restarting\":{{json .State.Restarting}},\"started\":{{json .State.StartedAt}},\"restarts\":{{json .RestartCount}},\"terminal\":{{json .Config.Tty}},\"openInput\":{{json .Config.OpenStdin}}}"

    /// 按 Docker CLI 的优先级（--context > --host/DOCKER_HOST > DOCKER_CONTEXT > config.json）直接读取 context 配置，省去每次启动 docker CLI；无法确定时返回 nil，由调用方回退 CLI。
    static func nativeContext(_ explicit: String?, environment: [String: String]) -> (context: String, endpoint: String)? {
        let directory = environment["DOCKER_CONFIG"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker")
        func json(_ url: URL) -> [String: Any]? { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        let host = environment["DOCKER_HOST"].flatMap { $0.isEmpty ? nil : $0 }
        let context: String
        if let explicit { context = explicit }
        else if host != nil { context = "default" }
        else if let name = environment["DOCKER_CONTEXT"], !name.isEmpty { context = name }
        else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) {
            guard let configuration = json(directory.appendingPathComponent("config.json")) else { return nil }
            context = (configuration["currentContext"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        } else { context = "default" }
        if context == "default" { return (context, host ?? "unix:///var/run/docker.sock") }
        let digest = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let meta = json(directory.appendingPathComponent("contexts/meta/\(digest)/meta.json")), meta["Name"] as? String == context,
              let endpoint = ((meta["Endpoints"] as? [String: Any])?["docker"] as? [String: Any])?["Host"] as? String, !endpoint.isEmpty else { return nil }
        return (context, endpoint)
    }
    public static func discover(terminal: LocalDockerTerminal, transport: SSHTransport? = nil, cancellation: CancellationFlag) throws -> DockerAttachmentSelection {
        if let host = terminal.host {
            guard let transport else { throw WorkbenchError.message(L10n.text("Docker context 无效，未发送附件。")) }
            return try discoverRemote(terminal: terminal, remote: RemoteDockerHost(transport: transport, host: host), cancellation: cancellation)
        }
        var environment = try LocalShellConfiguration().environment
        for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG"] { environment.removeValue(forKey: key) }
        environment.merge(terminal.environment) { _, value in value }
        if let configuration = environment["DOCKER_CONFIG"], !configuration.hasPrefix("/") {
            throw WorkbenchError.message(L10n.text("Docker context 无效，未发送附件。"))
        }
        if terminal.invocation.context == nil, terminal.invocation.host == nil,
           environment["DOCKER_CONTEXT"]?.isEmpty != false, environment["DOCKER_HOST"]?.isEmpty != false {
            let directory = environment["DOCKER_CONFIG"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker")
            let configuration = directory.appendingPathComponent("config.json")
            let started = Double(terminal.startedSeconds) + Double(terminal.startedMicroseconds) / 1_000_000
            let attributes = try FileManager.default.attributesOfItem(atPath: FileManager.default.fileExists(atPath: configuration.path) ? configuration.path : directory.path)
            guard let modified = attributes[.modificationDate] as? Date, modified.timeIntervalSince1970 <= started else {
                throw WorkbenchError.message(L10n.text("Docker 默认 context 配置在进入容器后发生变化，请显式指定 --context 重新连接容器。"))
            }
        }
        func run(_ arguments: [String]) throws -> String {
            try ProcessRunner.run(executable: terminal.executable, arguments: terminal.invocation.connectionArguments + arguments, environment: environment,
                                  cancellation: cancellation, timeout: 10).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let resolved = terminal.invocation.host == nil ? Self.nativeContext(terminal.invocation.context, environment: environment) : nil
        let context = try resolved?.context ?? run(["context", "show"])
        guard !context.isEmpty, !context.hasPrefix("-"), context.rangeOfCharacter(from: .controlCharacters) == nil else { throw WorkbenchError.message(L10n.text("Docker context 无效，未发送附件。")) }
        let endpoint = try resolved?.endpoint ?? run(["context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"])
        try DockerUnixEndpoint.validate(endpoint)
        let usesHost = terminal.invocation.host != nil || (context == "default" && environment["DOCKER_HOST"]?.isEmpty == false)
        environment.removeValue(forKey: "DOCKER_CONTEXT"); environment.removeValue(forKey: "DOCKER_HOST")
        let identity = try DockerEngineIdentity.read(endpoint: endpoint, cancellation: cancellation)
        let daemon = DockerAttachmentDaemon(context: context, endpoint: endpoint, identifier: identity.identifier, executable: terminal.executable, environment: environment, usesHost: usesHost, apiVersion: identity.apiVersion)
        // 目标容器由原窗格 docker 命令确定，不再列出全部容器供选择。
        let detected = try daemon.inspect(terminal.invocation.container, cancellation: cancellation)
        return DockerAttachmentSelection(daemon: daemon, terminal: terminal, containers: [detected], detectedContainerID: detected.id)
    }
    /// 远端沿用原窗格 docker 命令自带的 --context/--host 或其进程环境，不另行探测；目标身份以完整容器 ID 与状态逐次核对。
    private static func discoverRemote(terminal: LocalDockerTerminal, remote: RemoteDockerHost, cancellation: CancellationFlag) throws -> DockerAttachmentSelection {
        let invocation = terminal.invocation
        let usesHost = invocation.host != nil || (invocation.context == nil && terminal.environment["DOCKER_HOST"]?.isEmpty == false)
        let context = usesHost ? "" : invocation.context ?? terminal.environment["DOCKER_CONTEXT"] ?? ""
        let endpoint = usesHost ? invocation.host ?? terminal.environment["DOCKER_HOST"] ?? "" : ""
        guard [context, endpoint].allSatisfy({ !$0.hasPrefix("-") && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw WorkbenchError.message(L10n.text("Docker context 无效，未发送附件。"))
        }
        var environment = terminal.environment
        environment.removeValue(forKey: "DOCKER_CONTEXT"); environment.removeValue(forKey: "DOCKER_HOST")
        var daemon = DockerAttachmentDaemon(context: context, endpoint: endpoint, identifier: remote.host.id.uuidString + "|" + context + "|" + endpoint,
                                            executable: terminal.executable, environment: environment, usesHost: usesHost, apiVersion: "")
        daemon.remote = remote
        let detected = try daemon.inspect(invocation.container, cancellation: cancellation)
        return DockerAttachmentSelection(daemon: daemon, terminal: terminal, containers: [detected], detectedContainerID: detected.id)
    }
    /// revalidate 为 false 仅用于刚完成 discover、daemon 身份已核对的情况。
    public func confirm(_ containerID: String, terminal: LocalDockerTerminal, revalidate: Bool = true, cancellation: CancellationFlag) throws -> DockerAttachmentBinding {
        if revalidate { try validate(cancellation: cancellation) }
        let (pair, raw) = try inspectPair(containerID, terminal.invocation.container, cancellation: cancellation)
        guard pair.count == 2, let container = pair.first, container.id == containerID, pair[1].id == container.id,
              container.running, !container.paused, !container.restarting,
              !terminal.invocation.attachesExistingProcess || (container.terminal && container.openInput) else {
            throw WorkbenchError.message(L10n.text("所选容器不是原窗格正在使用的运行中容器，请重新选择。"))
        }
        let configuredUser = terminal.invocation.user ?? container.user
        let userArguments = configuredUser.isEmpty ? [] : ["--user", configuredUser]
        // 一次 exec 同时确认所需命令与接收用户，减少 docker CLI 往返。
        let identity = try run(["exec"] + userArguments + [container.id, "sh", "-c", "set -eu; for tool in sh id mktemp mkdir cat chmod sha256sum rm; do command -v \"$tool\" >/dev/null; done; id -u; id -g"], cancellation: cancellation).text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let uid = identity.count == 2 ? identity[0] : "", gid = identity.count == 2 ? identity[1] : ""
        guard !uid.isEmpty, !gid.isEmpty, uid.utf8.allSatisfy({ (48...57).contains($0) }), gid.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw WorkbenchError.message(L10n.text("无法确认容器接收用户，不会提权上传。"))
        }
        return DockerAttachmentBinding(daemon: self, container: container, terminal: terminal, user: uid + ":" + gid,
                                       fingerprint: String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .newlines))
    }
    public func validate(_ binding: DockerAttachmentBinding, cancellation: CancellationFlag) throws {
        try validate(cancellation: cancellation)
        let containers = try inspectPair(binding.container.id, binding.terminal.invocation.container, cancellation: cancellation).containers
        guard containers.count == 2, let current = containers.first, binding.daemon == self, current == binding.container,
              current.running, !current.paused, !current.restarting, current.id == containers[1].id else {
            throw WorkbenchError.message(L10n.text("Docker 服务、容器身份或启动状态已变化，请重新确认附件目标。"))
        }
    }
    private func validate(cancellation: CancellationFlag) throws {
        if remote != nil { return }
        if !usesHost {
            let current = try Self.nativeContext(context, environment: environment)?.endpoint ?? ProcessRunner.run(executable: executable, arguments: ["--context", context, "context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"], environment: environment, cancellation: cancellation, timeout: 10).checked().text
            guard current.trimmingCharacters(in: .whitespacesAndNewlines) == endpoint else { throw WorkbenchError.message(L10n.text("Docker 服务、容器身份或启动状态已变化，请重新确认附件目标。")) }
        }
        let current = try DockerEngineIdentity.read(endpoint: endpoint, apiVersion: apiVersion, cancellation: cancellation).identifier
        guard current == identifier else { throw WorkbenchError.message(L10n.text("Docker 服务、容器身份或启动状态已变化，请重新确认附件目标。")) }
    }
    /// 本机 daemon 优先经 socket API 读取容器（省去 docker CLI 启动开销）；远端或无法使用时返回 nil。
    private func socketInspect(_ reference: String, cancellation: CancellationFlag) throws -> DockerContainer? {
        guard remote == nil, !apiVersion.isEmpty else { return nil }
        return try DockerEngineIdentity.container(reference, endpoint: endpoint, apiVersion: apiVersion, cancellation: cancellation)
    }
    /// 同时读取所选容器与原窗格容器引用；raw 为 CLI 原始输出，仅远端用于原子比对。
    private func inspectPair(_ first: String, _ second: String, cancellation: CancellationFlag) throws -> (containers: [DockerContainer], raw: Data) {
        if let one = try socketInspect(first, cancellation: cancellation), let two = try socketInspect(second, cancellation: cancellation) { return ([one, two], Data()) }
        let raw = try run(["inspect", "--type", "container", "--format", Self.containerFormat, first, second], cancellation: cancellation).output
        return (try raw.split(separator: 10).map { try JSONDecoder().decode(DockerContainer.self, from: Data($0)) }, raw)
    }
    private func inspect(_ reference: String, cancellation: CancellationFlag) throws -> DockerContainer {
        if let container = try socketInspect(reference, cancellation: cancellation) { return container }
        let result = try run(["inspect", "--type", "container", "--format", Self.containerFormat, reference], cancellation: cancellation)
        return try JSONDecoder().decode(DockerContainer.self, from: result.output)
    }
    private func run(_ arguments: [String], input: Data? = nil, cancellation: CancellationFlag, timeout: TimeInterval? = nil, outputLimit: Int = 2 * 1024 * 1024,
                     guardedBy precheck: (arguments: [String], expected: String)? = nil) throws -> CommandResult {
        let result: CommandResult
        if let remote {
            let assignments = environment.sorted { $0.key < $1.key }.map { RemotePath.quote($0.key + "=" + $0.value) }
            func docker(_ arguments: [String]) -> String { "env " + (assignments + ([executable] + connection + arguments).map(RemotePath.quote)).joined(separator: " ") }
            var command = RemoteDockerHost.path + "; "
            if let precheck { command += "farport_state=$(" + docker(precheck.arguments) + ") && [ \"$farport_state\" = " + RemotePath.quote(precheck.expected) + " ] || exit 97; " }
            command += "exec " + docker(arguments)
            result = try remote.transport.run(remote.host, command: "/bin/sh -c " + RemotePath.quote(command), input: input, cancellation: cancellation,
                                              timeout: timeout ?? (input == nil ? 20 : 180), outputLimit: outputLimit)
        } else {
            result = try ProcessRunner.run(executable: executable, arguments: connection + arguments, environment: environment,
                                           cancellation: cancellation, timeout: timeout ?? (input == nil ? 15 : 120), outputLimit: outputLimit, input: input)
        }
        if precheck != nil, result.status == 97 { throw WorkbenchError.message(L10n.text("Docker 服务、容器身份或启动状态已变化，请重新确认附件目标。")) }
        guard result.status == 0 else { throw WorkbenchError.message(L10n.text("Docker 操作失败，请检查容器状态、目标用户权限及所需命令；未插入附件路径。")) }
        return result
    }
    func execute(_ binding: DockerAttachmentBinding, script: String, arguments: [String] = [], input: Data? = nil, cancellation: CancellationFlag, timeout: TimeInterval? = nil, outputLimit: Int = 2 * 1024 * 1024) throws -> CommandResult {
        let guarded = remote != nil && !binding.fingerprint.isEmpty && binding.daemon == self
        if !guarded { try validate(binding, cancellation: cancellation) }
        return try run(["exec", "-i", "--user", binding.user, binding.container.id, "sh", "-c", script, "farport-attachments"] + arguments, input: input, cancellation: cancellation, timeout: timeout, outputLimit: outputLimit,
                       guardedBy: guarded ? (["inspect", "--type", "container", "--format", Self.containerFormat, binding.container.id, binding.terminal.invocation.container], binding.fingerprint) : nil)
    }
    public func agentTerminal(_ binding: DockerAttachmentBinding, command: String, cancellation: CancellationFlag) throws -> TerminalProcessLaunch {
        guard remote == nil else { throw WorkbenchError.message(L10n.text("远端容器暂不支持在 Farport 中直接打开 Agent 终端。")) }
        try validate(binding, cancellation: cancellation)
        return TerminalProcessLaunch(executable: executable, arguments: ["--host", endpoint, "exec", "-it", "--user", binding.user, binding.container.id,
                                                                       "sh", "-c", "exec \"${SHELL:-/bin/sh}\" -l -c \"$1\"", "farport-agent", command], environment: environment)
    }
}

public struct DockerUploadedAttachments: Sendable {
    public let uploaded: UploadedAttachments
    let hashes: [String: String]
    let directories: [String: Set<String>]
}

public struct DockerAttachmentUploader: Sendable {
    public let binding: DockerAttachmentBinding
    public init(binding: DockerAttachmentBinding) { self.binding = binding }

    public func upload(_ files: [URL], transport: SSHTransport, cancellation: CancellationFlag,
                       progress: @escaping (String, Double) -> Void) throws -> DockerUploadedAttachments {
        try cancellation.check()
        guard !files.isEmpty, files.count <= 100 else { throw WorkbenchError.message(L10n.text("容器附件包含不支持的类型或超过数量、层级限制。")) }
        let local = LocalFileClient(cancellation: cancellation)
        var entries: [(source: String, relative: String, directory: Bool, size: UInt64)] = []
        var total: UInt64 = 0
        func walk(_ source: String, relative: String, depth: Int) throws {
            let attributes = try local.stat(source)
            guard depth < 64, entries.count < 1000, !attributes.isSymbolicLink, attributes.isDirectory || attributes.isRegularFile else { throw WorkbenchError.message(L10n.text("容器附件包含不支持的类型或超过数量、层级限制。")) }
            if !attributes.isDirectory {
                guard attributes.size <= 128 * 1024 * 1024, total <= 256 * 1024 * 1024 - attributes.size else { throw WorkbenchError.message(L10n.text("容器附件单文件最多 128 MiB，每批最多 256 MiB。")) }
                total += attributes.size
            }
            entries.append((source, relative, attributes.isDirectory, attributes.size))
            if attributes.isDirectory { for child in try local.list(source) { try walk(child.path, relative: RemotePath.join(relative, child.name), depth: depth + 1) } }
        }
        for file in files { try walk(file.path, relative: file.lastPathComponent, depth: 0) }
        if entries.count == 1, let entry = entries.first, !entry.directory {
            return try uploadFile(URL(fileURLWithPath: entry.source), size: entry.size, cancellation: cancellation, progress: progress)
        }
        try binding.daemon.validate(binding, cancellation: cancellation)
        let localUploader = AttachmentUploader(transport: transport)
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("farport-container-stage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let staging = try localUploader.upload(files, host: nil, directory: stagingRoot.path, cancellation: cancellation) { message, value in progress(message, value * 0.3) }
        entries = []; total = 0
        for source in staging.paths { try walk(source, relative: (source as NSString).lastPathComponent, depth: 0) }
        let directory = try binding.daemon.execute(binding, script: "umask 077; mktemp -d /tmp/.farport-attachments-XXXXXXXXXXXX", cancellation: cancellation).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validDirectory(directory) else { throw WorkbenchError.message(L10n.text("容器未返回安全的附件暂存目录。")) }
        var finished = false
        defer { if !finished { try? cleanup(directory, cancellation: CancellationFlag()) } }
        var hashes: [String: String] = [:]
        var directories: [String: Set<String>] = [directory: []]
        for (index, entry) in entries.enumerated() {
            try cancellation.check()
            let target = RemotePath.join(directory, entry.relative)
            directories[RemotePath.parent(target), default: []].insert((target as NSString).lastPathComponent)
            if entry.directory {
                directories[target] = []
                _ = try binding.daemon.execute(binding, script: "set -eu; umask 077; mkdir -- \"$1\"", arguments: [target], cancellation: cancellation)
            } else {
                let data = try Data(contentsOf: URL(fileURLWithPath: entry.source))
                guard data.count == entry.size else { throw WorkbenchError.message(L10n.text("附件目录在上传期间发生变化")) }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                _ = try binding.daemon.execute(binding, script: "set -eu; umask 077; set -C; cat > \"$1\"; chmod 600 -- \"$1\"", arguments: [target], input: data, cancellation: cancellation)
                hashes[target] = digest
            }
            progress(L10n.text("正在复制到容器并校验读取权限…"), 0.3 + 0.6 * Double(index + 1) / Double(entries.count))
        }
        let uploaded = UploadedAttachments(directory: directory, paths: staging.paths.map { RemotePath.join(directory, ($0 as NSString).lastPathComponent) }, fileCount: staging.fileCount)
        let result = DockerUploadedAttachments(uploaded: uploaded, hashes: hashes, directories: directories)
        try verify(result, cancellation: cancellation)
        finished = true; progress(L10n.text("容器内文件内容与读取权限校验通过"), 1)
        return result
    }
    private func uploadFile(_ file: URL, size: UInt64, cancellation: CancellationFlag, progress: (String, Double) -> Void) throws -> DockerUploadedAttachments {
        let local = LocalFileClient(cancellation: cancellation)
        let before = try local.stat(file.path)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(size) + 1) ?? Data()
        let after = try local.stat(file.path)
        guard before.isRegularFile, after.isRegularFile, !before.isSymbolicLink, !after.isSymbolicLink,
              data.count == size, before.size == after.size, before.modified == after.modified else {
            throw WorkbenchError.message(L10n.text("附件目录在上传期间发生变化"))
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        progress(L10n.text("正在复制到容器并校验读取权限…"), 0.2)
        let script = """
        set -eu; umask 077
        directory=$(mktemp -d /tmp/.farport-attachments-XXXXXXXXXXXX)
        trap 'rm -rf -- "$directory"' EXIT
        set -C; cat > "$directory/$1"; chmod 600 -- "$directory/$1"
        test ! -L "$directory/$1"; test -r "$directory/$1"
        digest=$(sha256sum < "$directory/$1")
        printf '%s\\n%s\\n' "$directory" "$digest"
        trap - EXIT
        """
        let output = try binding.daemon.execute(binding, script: script, arguments: [file.lastPathComponent], input: data, cancellation: cancellation).text.split(separator: "\n").map(String.init)
        guard output.count == 2, Self.validDirectory(output[0]) else { throw WorkbenchError.message(L10n.text("容器未返回安全的附件暂存目录。")) }
        let directory = output[0]
        var finished = false
        defer { if !finished { try? cleanup(directory, cancellation: CancellationFlag()) } }
        guard output[1].split(whereSeparator: \.isWhitespace).first.map(String.init) == digest else {
            throw WorkbenchError.message(L10n.text("容器附件内容已变化，未插入路径。"))
        }
        let path = RemotePath.join(directory, file.lastPathComponent)
        let result = DockerUploadedAttachments(uploaded: UploadedAttachments(directory: directory, paths: [path], fileCount: 1),
                                              hashes: [path: digest], directories: [directory: [file.lastPathComponent]])
        finished = true; progress(L10n.text("容器内文件内容与读取权限校验通过"), 1)
        return result
    }
    public func verify(_ result: DockerUploadedAttachments, cancellation: CancellationFlag) throws {
        guard Self.validDirectory(result.uploaded.directory) else { throw WorkbenchError.message(L10n.text("容器未返回安全的附件暂存目录。")) }
        let paths = result.uploaded.paths
        let directories = result.directories.sorted { $0.key < $1.key }
        let hashes = result.hashes.sorted { $0.key < $1.key }
        for offset in stride(from: 0, to: max(paths.count, directories.count, hashes.count), by: 8) {
            try verifyBatch(paths: Array(paths.dropFirst(offset).prefix(8)), directories: Array(directories.dropFirst(offset).prefix(8)),
                            hashes: Array(hashes.dropFirst(offset).prefix(8)), cancellation: cancellation)
        }
    }
    private func verifyBatch(paths: [String], directories: [(key: String, value: Set<String>)], hashes: [(key: String, value: String)], cancellation: CancellationFlag) throws {
        var script = "set -eu\n"
        var arguments: [String] = []
        for path in paths {
            script += "test ! -L \"$1\"; test -r \"$1\"; shift\n"
            arguments.append(path)
        }
        for (directory, _) in directories {
            script += "test ! -L \"$1\"; test -d \"$1\"; test -r \"$1\"; test -x \"$1\"; for child in \"$1\"/* \"$1\"/.[!.]* \"$1\"/..?*; do if [ -e \"$child\" ] || [ -L \"$child\" ]; then printf '%s\\0' \"${child##*/}\"; fi; done; printf '\\0'; shift\n"
            arguments.append(directory)
        }
        for (path, _) in hashes {
            script += "test ! -L \"$1\"; sha256sum < \"$1\"; shift\n"
            arguments.append(path)
        }
        let data = try binding.daemon.execute(binding, script: script, arguments: arguments, cancellation: cancellation).output
        guard let text = String(data: data, encoding: .utf8) else { throw WorkbenchError.message(L10n.text("容器附件内容已变化，未插入路径。")) }
        var parts = text.components(separatedBy: "\0")[...]
        for (_, names) in directories {
            let children = parts.prefix(while: { !$0.isEmpty })
            guard Set(children) == names, children.count == names.count, parts.dropFirst(children.count).first == "" else {
                throw WorkbenchError.message(L10n.text("容器附件内容已变化，未插入路径。"))
            }
            parts = parts.dropFirst(children.count + 1)
        }
        guard parts.count == 1 else { throw WorkbenchError.message(L10n.text("容器附件内容已变化，未插入路径。")) }
        let actual = parts.first!.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "" }
        guard actual == hashes.map(\.value) else { throw WorkbenchError.message(L10n.text("容器附件内容已变化，未插入路径。")) }
    }
    public func cleanup(_ directory: String, cancellation: CancellationFlag) throws {
        guard Self.validDirectory(directory) else { throw WorkbenchError.message(L10n.text("拒绝清理非附件目录")) }
        _ = try binding.daemon.execute(binding, script: "test ! -L \"$1\" && rm -rf -- \"$1\"", arguments: [directory], cancellation: cancellation)
    }
    private static func validDirectory(_ directory: String) -> Bool {
        let prefix = "/tmp/.farport-attachments-"
        return directory.hasPrefix(prefix) && directory.count > prefix.count && directory.dropFirst(prefix.count).utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
}
