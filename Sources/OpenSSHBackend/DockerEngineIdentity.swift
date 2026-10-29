import Foundation
import WorkbenchCore

public struct DockerEngineIdentity: Equatable, Sendable {
    public let apiVersion: String
    public let identifier: String

    public static func read(endpoint: String, apiVersion: String? = nil, cancellation: CancellationFlag = CancellationFlag()) throws -> Self {
        try DockerUnixEndpoint.validate(endpoint)
        let version: String
        if let apiVersion { version = apiVersion }
        else { version = try field("ApiVersion", path: "/version", endpoint: endpoint, cancellation: cancellation) }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ (1...3).contains($0.utf8.count) && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            throw WorkbenchError.message(L10n.text("无法确认 Docker 服务身份。"))
        }
        let identifier = try field("ID", path: "/v" + version + "/info", endpoint: endpoint, cancellation: cancellation)
        guard !identifier.isEmpty, identifier.utf8.count <= 256, identifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              identifier.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WorkbenchError.message(L10n.text("无法确认 Docker 服务身份。"))
        }
        return Self(apiVersion: version, identifier: identifier)
    }

    /// 经本机 socket 读取容器状态，字段与 CLI inspect 模板一致；引用含非常规字符时返回 nil，由调用方回退 CLI。
    public static func container(_ reference: String, endpoint: String, apiVersion: String, cancellation: CancellationFlag = CancellationFlag()) throws -> DockerContainer? {
        guard !reference.isEmpty, reference.utf8.count <= 128, !reference.hasPrefix("-"), !reference.hasPrefix("."),
              reference.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else { return nil }
        let object = try request(path: "/v" + apiVersion + "/containers/" + reference + "/json", endpoint: endpoint, cancellation: cancellation,
                                 failure: L10n.text("Docker 操作失败，请检查容器状态、目标用户权限及所需命令；未插入附件路径。"))
        let configuration = object["Config"] as? [String: Any] ?? [:], state = object["State"] as? [String: Any] ?? [:]
        guard let id = object["Id"] as? String, let name = object["Name"] as? String, let running = state["Running"] as? Bool, let paused = state["Paused"] as? Bool,
              let restarting = state["Restarting"] as? Bool, let started = state["StartedAt"] as? String, let restarts = object["RestartCount"] as? Int else {
            throw WorkbenchError.message(L10n.text("Docker 操作失败，请检查容器状态、目标用户权限及所需命令；未插入附件路径。"))
        }
        return DockerContainer(id: id, name: name, user: configuration["User"] as? String ?? "", running: running, paused: paused, restarting: restarting,
                               started: started, restarts: restarts, terminal: configuration["Tty"] as? Bool ?? false, openInput: configuration["OpenStdin"] as? Bool ?? false)
    }

    private static func field(_ name: String, path: String, endpoint: String, cancellation: CancellationFlag) throws -> String {
        guard let value = try request(path: path, endpoint: endpoint, cancellation: cancellation, failure: L10n.text("无法确认 Docker 服务身份。"))[name] as? String else {
            throw WorkbenchError.message(L10n.text("无法确认 Docker 服务身份。"))
        }
        return value
    }
    private static func request(path: String, endpoint: String, cancellation: CancellationFlag, failure: String) throws -> [String: Any] {
        guard let socket = URLComponents(string: endpoint)?.path else { throw WorkbenchError.message(failure) }
        let result = try ProcessRunner.run(executable: "/usr/bin/curl",
                                           arguments: ["-q", "--proxy", "", "--noproxy", "*", "--proto", "=http", "--unix-socket", socket,
                                                       "--silent", "--show-error", "--connect-timeout", "3", "--max-time", "10", "--max-filesize", "2097152",
                                                       "--write-out", "\n%{http_code}", "http://localhost" + path],
                                           environment: ["PATH": "/usr/bin:/bin"], cancellation: cancellation, timeout: 12, outputLimit: 2 * 1024 * 1024 + 5)
        guard result.status == 0, result.output.suffix(4) == Data("\n200".utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(result.output.dropLast(4))) as? [String: Any] else {
            throw WorkbenchError.message(failure)
        }
        return object
    }
}
