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
}

public struct DockerAttachmentDaemon: Equatable, Sendable {
    public let context: String
    public let endpoint: String
    public let identifier: String
    private let executable: String
    private let environment: [String: String]
    private let usesHost: Bool
    public var connectionDescription: String { usesHost ? "Unix socket · " + endpoint : context }
    private static let containerFormat = "{\"id\":{{json .Id}},\"name\":{{json .Name}},\"user\":{{json .Config.User}},\"running\":{{json .State.Running}},\"paused\":{{json .State.Paused}},\"restarting\":{{json .State.Restarting}},\"started\":{{json .State.StartedAt}},\"restarts\":{{json .RestartCount}},\"terminal\":{{json .Config.Tty}},\"openInput\":{{json .Config.OpenStdin}}}"

    public static func discover(terminal: LocalDockerTerminal, cancellation: CancellationFlag) throws -> DockerAttachmentSelection {
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
        let context = try run(["context", "show"])
        guard !context.isEmpty, !context.hasPrefix("-"), context.rangeOfCharacter(from: .controlCharacters) == nil else { throw WorkbenchError.message(L10n.text("Docker context 无效，未发送附件。")) }
        let endpoint = try run(["context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"])
        try DockerUnixEndpoint.validate(endpoint)
        let usesHost = terminal.invocation.host != nil || (context == "default" && environment["DOCKER_HOST"]?.isEmpty == false)
        environment.removeValue(forKey: "DOCKER_CONTEXT"); environment.removeValue(forKey: "DOCKER_HOST")
        let identifier = try ProcessRunner.run(executable: terminal.executable, arguments: ["--host", endpoint, "info", "--format", "{{.ID}}"],
                                               environment: environment, cancellation: cancellation, timeout: 10).checked().text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw WorkbenchError.message(L10n.text("无法确认 Docker 服务身份。")) }
        let daemon = DockerAttachmentDaemon(context: context, endpoint: endpoint, identifier: identifier, executable: terminal.executable, environment: environment, usesHost: usesHost)
        let detected = try daemon.inspect(terminal.invocation.container, cancellation: cancellation)
        let identifiers = try daemon.run(["ps", "--no-trunc", "--format", "{{.ID}}"], cancellation: cancellation).text.split(separator: "\n").map(String.init)
        guard !identifiers.isEmpty, identifiers.count <= 100 else { throw WorkbenchError.message(L10n.text("没有可用容器或容器数量超过本次选择范围。")) }
        let result = try daemon.run(["inspect", "--type", "container", "--format", containerFormat] + identifiers, cancellation: cancellation)
        let containers = try result.text.split(separator: "\n").map { try JSONDecoder().decode(DockerContainer.self, from: Data($0.utf8)) }
        return DockerAttachmentSelection(daemon: daemon, terminal: terminal, containers: containers, detectedContainerID: detected.id)
    }
    public func confirm(_ containerID: String, terminal: LocalDockerTerminal, cancellation: CancellationFlag) throws -> DockerAttachmentBinding {
        try validate(cancellation: cancellation)
        let container = try inspect(containerID, cancellation: cancellation)
        guard container.id == containerID, container.id == (try inspect(terminal.invocation.container, cancellation: cancellation)).id,
              container.running, !container.paused, !container.restarting,
              !terminal.invocation.attachesExistingProcess || (container.terminal && container.openInput) else {
            throw WorkbenchError.message(L10n.text("所选容器不是原窗格正在使用的运行中容器，请重新选择。"))
        }
        let configuredUser = terminal.invocation.user ?? container.user
        let userArguments = configuredUser.isEmpty ? [] : ["--user", configuredUser]
        let uid = try run(["exec"] + userArguments + [container.id, "id", "-u"], cancellation: cancellation).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let gid = try run(["exec"] + userArguments + [container.id, "id", "-g"], cancellation: cancellation).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty, !gid.isEmpty, uid.utf8.allSatisfy({ (48...57).contains($0) }), gid.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw WorkbenchError.message(L10n.text("无法确认容器接收用户，不会提权上传。"))
        }
        let binding = DockerAttachmentBinding(daemon: self, container: container, terminal: terminal, user: uid + ":" + gid)
        _ = try execute(binding, script: "set -eu; for tool in sh id mktemp mkdir cat chmod sha256sum rm; do command -v \"$tool\" >/dev/null; done", cancellation: cancellation)
        return binding
    }
    public func validate(_ binding: DockerAttachmentBinding, cancellation: CancellationFlag) throws {
        try validate(cancellation: cancellation)
        let current = try inspect(binding.container.id, cancellation: cancellation)
        guard binding.daemon == self, current == binding.container, current.running, !current.paused, !current.restarting,
              current.id == (try inspect(binding.terminal.invocation.container, cancellation: cancellation)).id else {
            throw WorkbenchError.message(L10n.text("Docker 服务、容器身份或启动状态已变化，请重新确认附件目标。"))
        }
    }
    private func validate(cancellation: CancellationFlag) throws {
        if !usesHost {
            let result = try ProcessRunner.run(executable: executable, arguments: ["--context", context, "context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"], environment: environment, cancellation: cancellation, timeout: 10).checked()
            guard result.text.trimmingCharacters(in: .whitespacesAndNewlines) == endpoint else { throw WorkbenchError.message(L10n.text("Docker 服务、容器身份或启动状态已变化，请重新确认附件目标。")) }
        }
        let current = try run(["info", "--format", "{{.ID}}"], cancellation: cancellation).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == identifier else { throw WorkbenchError.message(L10n.text("Docker 服务、容器身份或启动状态已变化，请重新确认附件目标。")) }
    }
    private func inspect(_ reference: String, cancellation: CancellationFlag) throws -> DockerContainer {
        let result = try run(["inspect", "--type", "container", "--format", Self.containerFormat, reference], cancellation: cancellation)
        return try JSONDecoder().decode(DockerContainer.self, from: result.output)
    }
    private func run(_ arguments: [String], input: Data? = nil, cancellation: CancellationFlag) throws -> CommandResult {
        let result = try ProcessRunner.run(executable: executable, arguments: ["--host", endpoint] + arguments, environment: environment,
                                          cancellation: cancellation, timeout: input == nil ? 15 : 120, outputLimit: 2 * 1024 * 1024, input: input)
        guard result.status == 0 else { throw WorkbenchError.message(L10n.text("Docker 操作失败，请检查容器状态、目标用户权限及所需命令；未插入附件路径。")) }
        return result
    }
    func execute(_ binding: DockerAttachmentBinding, script: String, arguments: [String] = [], input: Data? = nil, cancellation: CancellationFlag) throws -> CommandResult {
        try validate(binding, cancellation: cancellation)
        return try run(["exec", "-i", "--user", binding.user, binding.container.id, "sh", "-c", script, "farport-attachments"] + arguments, input: input, cancellation: cancellation)
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
        try binding.daemon.validate(binding, cancellation: cancellation)
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
        let localUploader = AttachmentUploader(transport: transport)
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("farport-container-stage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let staging = try localUploader.upload(files, host: nil, directory: stagingRoot.path, cancellation: cancellation) { message, value in progress(message, value * 0.3) }
        entries = []; total = 0
        for source in staging.paths { try walk(source, relative: (source as NSString).lastPathComponent, depth: 0) }
        try binding.daemon.validate(binding, cancellation: cancellation)
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
    public func verify(_ result: DockerUploadedAttachments, cancellation: CancellationFlag) throws {
        try binding.daemon.validate(binding, cancellation: cancellation)
        guard Self.validDirectory(result.uploaded.directory) else { throw WorkbenchError.message(L10n.text("容器未返回安全的附件暂存目录。")) }
        for path in result.uploaded.paths {
            _ = try binding.daemon.execute(binding, script: "test ! -L \"$1\" && test -r \"$1\"", arguments: [path], cancellation: cancellation)
        }
        for (directory, names) in result.directories {
            let data = try binding.daemon.execute(binding, script: "set -eu; test ! -L \"$1\"; test -d \"$1\"; test -r \"$1\"; test -x \"$1\"; for child in \"$1\"/* \"$1\"/.[!.]* \"$1\"/..?*; do if [ -e \"$child\" ] || [ -L \"$child\" ]; then printf '%s\\0' \"${child##*/}\"; fi; done", arguments: [directory], cancellation: cancellation).output
            let children = data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
            guard Set(children) == names else { throw WorkbenchError.message(L10n.text("容器附件内容已变化，未插入路径。")) }
        }
        for (path, digest) in result.hashes {
            let output = try binding.daemon.execute(binding, script: "test ! -L \"$1\" && sha256sum < \"$1\"", arguments: [path], cancellation: cancellation).text
            guard output.split(whereSeparator: \.isWhitespace).first.map(String.init) == digest else { throw WorkbenchError.message(L10n.text("容器附件内容已变化，未插入路径。")) }
        }
    }
    public func cleanup(_ directory: String, cancellation: CancellationFlag) throws {
        guard Self.validDirectory(directory) else { throw WorkbenchError.message(L10n.text("拒绝清理非附件目录")) }
        try binding.daemon.validate(binding, cancellation: cancellation)
        _ = try binding.daemon.execute(binding, script: "test ! -L \"$1\" && rm -rf -- \"$1\"", arguments: [directory], cancellation: cancellation)
    }
    private static func validDirectory(_ directory: String) -> Bool {
        let prefix = "/tmp/.farport-attachments-"
        return directory.hasPrefix(prefix) && directory.count > prefix.count && directory.dropFirst(prefix.count).utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
}
