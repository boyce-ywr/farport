import Foundation

public struct TerminalLayout: Equatable {
    public private(set) var primary: UUID?
    public private(set) var secondary: UUID?
    public private(set) var focused: UUID?
    public init() {}
    public mutating func select(_ identifier: UUID) {
        if identifier != primary && identifier != secondary {
            if secondary != nil && focused == secondary { secondary = identifier }
            else { primary = identifier }
        }
        focused = identifier
    }
    public mutating func split(with identifier: UUID) {
        guard let primary, primary != identifier else { select(identifier); return }
        secondary = identifier; focused = identifier
    }
    public mutating func collapse() {
        primary = focused ?? primary; secondary = nil; focused = primary
    }
    public mutating func close(_ identifier: UUID, fallback: UUID?) {
        if primary == identifier { primary = secondary ?? fallback; secondary = nil }
        else if secondary == identifier { secondary = nil }
        if focused == identifier { focused = primary }
    }
}
