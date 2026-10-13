import Foundation

public enum HostMarkColor: String, CaseIterable, Sendable {
    case mint, blue, green, orange, yellow, red, pink, purple, indigo, gray
    public init(storedValue: String) { self = Self(rawValue: storedValue) ?? .mint }
    public var title: String {
        switch self {
        case .mint: return "青绿"
        case .blue: return "蓝色"
        case .green: return "绿色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .red: return "红色"
        case .pink: return "粉色"
        case .purple: return "紫色"
        case .indigo: return "靛蓝"
        case .gray: return "灰色"
        }
    }
}
