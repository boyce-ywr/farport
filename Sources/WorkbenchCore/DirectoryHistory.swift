import Foundation

public struct DirectoryHistory: Equatable {
    public private(set) var current: String?
    public private(set) var previous: [String] = []
    public init() {}
    public var backDestination: String? { previous.last }
    public mutating func visited(_ path: String) {
        guard path != current else { return }
        if let current { previous.append(current); if previous.count > 100 { previous.removeFirst() } }
        current = path
    }
    public mutating func returned(to path: String) {
        guard !previous.isEmpty else { return }
        previous.removeLast(); current = path
    }
}
