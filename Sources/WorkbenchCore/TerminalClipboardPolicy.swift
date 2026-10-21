import Foundation

public enum TerminalClipboardWritePolicy: String, CaseIterable, Identifiable {
    case ask, allow, deny
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ask: return L10n.text("每次连接首次询问")
        case .allow: return L10n.text("始终允许写入，不再询问")
        case .deny: return L10n.text("禁止终端写入")
        }
    }
    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .ask }
}
