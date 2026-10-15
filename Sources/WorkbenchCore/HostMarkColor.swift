import Foundation

public enum HostMarkColor: String, CaseIterable, Sendable {
    case mint, blue, green, orange, yellow, red, pink, purple, indigo, gray
    public init(storedValue: String) { self = Self(rawValue: storedValue) ?? .mint }
    public var title: String {
        switch self {
        case .mint: return L10n.text("青绿")
        case .blue: return L10n.text("蓝色")
        case .green: return L10n.text("绿色")
        case .orange: return L10n.text("橙色")
        case .yellow: return L10n.text("黄色")
        case .red: return L10n.text("红色")
        case .pink: return L10n.text("粉色")
        case .purple: return L10n.text("紫色")
        case .indigo: return L10n.text("靛蓝")
        case .gray: return L10n.text("灰色")
        }
    }
}
