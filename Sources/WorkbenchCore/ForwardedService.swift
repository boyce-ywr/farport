import Foundation

public struct ForwardedService: Codable, Equatable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    public var connectionKey: String
    public var name: String
    public var target: String
    public var port: Int
    public var scheme: String
    public var path: String
    public init(id: UUID = UUID(), hostID: UUID, connectionKey: String, name: String = "", target: String = "127.0.0.1", port: Int = 8080, scheme: String = "http", path: String = "/") {
        self.id = id; self.hostID = hostID; self.connectionKey = connectionKey; self.name = name
        self.target = target; self.port = port; self.scheme = scheme; self.path = path
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              ["http", "https"].contains(scheme), path.hasPrefix("/"), path.utf8.count <= 2048,
              !path.contains("?"), !path.contains("#"), path.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil,
              (try? ScreenSharingEndpoint(host: target, port: port)) != nil else {
            throw WorkbenchError.message(L10n.text("请输入服务名称、有效地址和端口；路径须以 / 开头，不能保存查询参数、令牌或片段标记。"))
        }
    }
    public func localURL(port: Int) throws -> URL {
        try validate()
        guard (1...65535).contains(port) else { throw WorkbenchError.message(L10n.text("本机转发端口无效。")) }
        var components = URLComponents(); components.scheme = scheme; components.host = "127.0.0.1"; components.port = port; components.path = path
        guard let url = components.url else { throw WorkbenchError.message(L10n.text("无法生成本机服务地址。")) }
        return url
    }
}
