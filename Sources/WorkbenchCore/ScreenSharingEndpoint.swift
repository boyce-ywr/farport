import Foundation

public struct ScreenSharingEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
    public init(host: String, port: Int = 5900) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        guard !host.isEmpty, !host.hasPrefix("-"), host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }), (1...65535).contains(port) else {
            throw WorkbenchError.message(L10n.text("请输入有效的桌面 IP 或域名及 1–65535 端口，不要输入账号、密码或 URL。"))
        }
        self.host = host; self.port = port
    }
    public var forwardingTarget: String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }
    public var url: URL? {
        var components = URLComponents(); components.scheme = "vnc"
        components.host = host.contains(":") ? "[\(host)]" : host; components.port = port
        return components.url
    }
}
