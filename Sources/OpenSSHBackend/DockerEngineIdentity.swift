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

    private static func field(_ name: String, path: String, endpoint: String, cancellation: CancellationFlag) throws -> String {
        guard let socket = URLComponents(string: endpoint)?.path else { throw WorkbenchError.message(L10n.text("无法确认 Docker 服务身份。")) }
        let result = try ProcessRunner.run(executable: "/usr/bin/curl",
                                           arguments: ["-q", "--proxy", "", "--noproxy", "*", "--proto", "=http", "--unix-socket", socket,
                                                       "--silent", "--show-error", "--connect-timeout", "3", "--max-time", "10", "--max-filesize", "2097152",
                                                       "--write-out", "\n%{http_code}", "http://localhost" + path],
                                           environment: ["PATH": "/usr/bin:/bin"], cancellation: cancellation, timeout: 12, outputLimit: 2 * 1024 * 1024 + 5)
        guard result.status == 0, result.output.suffix(4) == Data("\n200".utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(result.output.dropLast(4))) as? [String: Any],
              let value = object[name] as? String else {
            throw WorkbenchError.message(L10n.text("无法确认 Docker 服务身份。"))
        }
        return value
    }
}
