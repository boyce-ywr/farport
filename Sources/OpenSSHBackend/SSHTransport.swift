import Foundation
import Darwin
import CryptoKit
import WorkbenchCore

public struct ApplicationPaths: Sendable {
    public let root: URL
    public let sockets: URL
    public var hosts: URL { root.appendingPathComponent("hosts.json") }
    public var transfers: URL { root.appendingPathComponent("transfers.json") }
    public var knownHosts: URL { root.appendingPathComponent("known_hosts") }
    public init(root: URL) throws {
        self.root = root
        let hash = root.path.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        sockets = URL(fileURLWithPath: "/tmp/swb-\(getuid())-\(String(hash, radix: 16).prefix(8))")
        for directory in [root, sockets] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw WorkbenchError.message(L10n.text("应用数据目录的所有权不安全：\(directory.lastPathComponent)"))
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        if !FileManager.default.fileExists(atPath: knownHosts.path) {
            FileManager.default.createFile(atPath: knownHosts.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }
    public func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

public struct CommandResult: Sendable {
    public let output: Data
    public let error: String
    public let status: Int32
    public var text: String { String(decoding: output, as: UTF8.self) }
    public func checked() throws -> CommandResult {
        guard status == 0 else { throw WorkbenchError.message(error.isEmpty ? L10n.text("远程命令失败（\(status)）。") : error) }
        return self
    }
}

public struct ConnectionTestResult: Sendable {
    public let elapsed: TimeInterval
    public let sftpAvailable: Bool
    public let detail: String
}

final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func append(_ data: Data, limit: Int) { lock.lock(); defer { lock.unlock() }; if value.count < limit { value.append(data.prefix(limit - value.count)) } }
    var data: Data { lock.lock(); defer { lock.unlock() }; return value }
}

public enum ProcessRunner {
    public static func run(executable: String, arguments: [String], environment: [String: String]? = nil,
                           cancellation: CancellationFlag = CancellationFlag(), timeout: TimeInterval = 45,
                           outputLimit: Int = 8 * 1024 * 1024) throws -> CommandResult {
        try cancellation.check()
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe(); let error = Pipe()
        process.standardOutput = output; process.standardError = error; process.standardInput = FileHandle.nullDevice
        let captured = CapturedOutput(); let errors = CapturedOutput(); let readers = DispatchGroup()
        try process.run()
        for (pipe, destination, limit) in [(output, captured, outputLimit), (error, errors, 64 * 1024)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                while let data = try? pipe.fileHandleForReading.read(upToCount: 65536), !data.isEmpty { destination.append(data, limit: limit) }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if cancellation.isCancelled || Date() > deadline {
                timedOut = !cancellation.isCancelled; process.terminate()
                Thread.sleep(forTimeInterval: 0.15)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        _ = readers.wait(timeout: .now() + 3)
        try? output.fileHandleForReading.close(); try? error.fileHandleForReading.close()
        try cancellation.check()
        if timedOut { throw WorkbenchError.message(L10n.text("操作超时，连接已关闭。请检查网络、跳板机和远端状态。")) }
        return CommandResult(output: captured.data, error: String(decoding: errors.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), status: process.terminationStatus)
    }
}

public final class SSHTransport: @unchecked Sendable {
    public let paths: ApplicationPaths
    public let askpass: String?
    public let noninteractive: Bool
    public init(paths: ApplicationPaths, askpass: String? = nil, noninteractive: Bool = false) {
        self.paths = paths; self.askpass = askpass; self.noninteractive = noninteractive
    }
    public func environment(for host: HostProfile) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"
        environment["LANG"] = "en_US.UTF-8"
        if let askpass, !noninteractive {
            environment["SSH_ASKPASS"] = askpass; environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "ssh-workbench"; environment["SWB_CREDENTIAL_ACCOUNT"] = host.id.uuidString + ":" + connectionDigest(host)
            environment["SWB_HOST_LABEL"] = host.name
            environment["FARPORT_LANGUAGE"] = L10n.language.rawValue
        }
        return environment
    }
    public func options(for host: HostProfile, reuseConnection: Bool = true) throws -> [String] {
        try host.validate()
        let socketName = String(connectionDigest(host).prefix(12)) + "-%C"
        var arguments = ["-p", String(host.port), "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=1",
                         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                         "-o", "StrictHostKeyChecking=\(noninteractive ? "yes" : "ask")",
                         "-o", "UserKnownHostsFile=\"\(paths.knownHosts.path)\"", "-o", "UpdateHostKeys=no",
                         "-o", "ControlMaster=auto", "-o", "ControlPersist=60",
                         "-o", "ControlPath=\(paths.sockets.appendingPathComponent(socketName).path)",
                         "-o", "ForwardAgent=no", "-o", "NumberOfPasswordPrompts=2", "-o", "LogLevel=ERROR"]
        if noninteractive { arguments += ["-o", "BatchMode=yes"] }
        if let config = host.configFile { arguments = ["-F", config] + arguments }
        if !host.username.isEmpty { arguments += ["-l", host.username] }
        if !host.identityFile.isEmpty { arguments += ["-i", NSString(string: host.identityFile).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        if !host.jumpHost.isEmpty { arguments += ["-J", host.jumpHost] }
        if !reuseConnection { arguments = ["-o", "ControlMaster=no", "-o", "ControlPath=none"] + arguments }
        return arguments
    }
    private func connectionDigest(_ host: HostProfile) -> String { SHA256.hash(data: Data((host.id.uuidString + host.connectionKey).utf8)).map { String(format: "%02x", $0) }.joined() }
    public func terminalArguments(for host: HostProfile, tmuxSession: String? = nil) throws -> [String] {
        var result = try options(for: host) + ["-tt", host.address]
        if let tmuxSession { result += [RemoteTmuxCommand.attach(session: tmuxSession)] }
        return result
    }
    public func forwardingArguments(for host: HostProfile, kind: ForwardingKind, port: Int, target: String = "127.0.0.1", targetPort: Int = 80) throws -> [String] {
        guard (1...65535).contains(port), (1...65535).contains(targetPort), !target.isEmpty,
              target.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !target.contains("/"), !target.hasPrefix("-") else { throw WorkbenchError.message(L10n.text("请检查监听端口、目标主机和目标端口。")) }
        if target.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, target, &address) == 1 else { throw WorkbenchError.message(L10n.text("目标 IPv6 地址格式不正确。")) }
        }
        let destination = target.contains(":") ? "[\(target)]" : target
        let binding = kind == .dynamic ? "127.0.0.1:\(port)" : "127.0.0.1:\(port):\(destination):\(targetPort)"
        let option = kind == .local ? "-L" : (kind == .remote ? "-R" : "-D")
        return try ["-o", "ControlMaster=no", "-o", "ControlPath=none"] + options(for: host) + ["-N", "-o", "ExitOnForwardFailure=yes", option, binding, host.address]
    }
    public func run(_ host: HostProfile, command: String, cancellation: CancellationFlag = CancellationFlag(), timeout: TimeInterval = 45) throws -> CommandResult {
        try ProcessRunner.run(executable: "/usr/bin/ssh", arguments: options(for: host) + [host.address, command], environment: environment(for: host), cancellation: cancellation, timeout: timeout)
    }
    public func sftp(_ host: HostProfile, cancellation: CancellationFlag = CancellationFlag()) throws -> SFTPClient { try SFTPClient(transport: self, host: host, cancellation: cancellation) }
    public func testConnection(_ draft: HostProfile, cancellation: CancellationFlag = CancellationFlag()) throws -> ConnectionTestResult {
        var host = draft
        if host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { host.name = host.address }
        try host.validate()
        let started = Date()
        _ = try ProcessRunner.run(executable: "/usr/bin/ssh", arguments: options(for: host, reuseConnection: false) + [host.address, "true"],
                                  environment: environment(for: host), cancellation: cancellation, timeout: 120).checked()
        do {
            let client = try SFTPClient(transport: self, host: host, cancellation: cancellation, reuseConnection: false)
            defer { client.close() }
            _ = try client.realpath()
            try cancellation.check()
            return ConnectionTestResult(elapsed: Date().timeIntervalSince(started), sftpAvailable: true, detail: L10n.text("SSH 认证与 SFTP 文件访问均通过。"))
        } catch {
            try cancellation.check()
            return ConnectionTestResult(elapsed: Date().timeIntervalSince(started), sftpAvailable: false, detail: L10n.text("SSH 已连接，但 SFTP 不可用：\(error.localizedDescription)"))
        }
    }
    public func disconnectMaster(_ host: HostProfile) {
        _ = try? ProcessRunner.run(executable: "/usr/bin/ssh", arguments: options(for: host) + ["-O", "exit", host.address], environment: environment(for: host), timeout: 3)
    }
}
