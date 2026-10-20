import Foundation

public enum DockerUnixEndpoint {
    public static func validate(_ endpoint: String) throws {
        guard endpoint.hasPrefix("unix:///"), endpoint.count > "unix:///".count,
              endpoint.rangeOfCharacter(from: .controlCharacters) == nil,
              let components = URLComponents(string: endpoint), components.scheme == "unix",
              components.host?.isEmpty != false, components.user == nil, components.password == nil,
              components.port == nil, components.query == nil, components.fragment == nil,
              components.path.hasPrefix("/"), components.path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WorkbenchError.message(L10n.text("容器附件仅支持本机 Unix socket；TCP、SSH 或无效 Docker 地址不会接收附件。"))
        }
    }
}
