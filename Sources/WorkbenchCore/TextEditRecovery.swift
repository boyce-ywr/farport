import Foundation

public struct TextChangePreview: Equatable {
    public let firstLine: Int
    public let removedCount: Int
    public let addedCount: Int
    public let removed: String
    public let added: String
    public let truncated: Bool
    public var isEmpty: Bool { removedCount == 0 && addedCount == 0 }
    public init(original: String, edited: String, limit: Int = 200) {
        let before = original.isEmpty ? [] : original.components(separatedBy: "\n")
        let after = edited.isEmpty ? [] : edited.components(separatedBy: "\n")
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var oldEnd = before.count; var newEnd = after.count
        while oldEnd > prefix, newEnd > prefix, before[oldEnd - 1] == after[newEnd - 1] { oldEnd -= 1; newEnd -= 1 }
        let maximum = min(500, max(1, limit))
        firstLine = prefix + 1; removedCount = oldEnd - prefix; addedCount = newEnd - prefix
        removed = before[prefix..<oldEnd].prefix(maximum).joined(separator: "\n")
        added = after[prefix..<newEnd].prefix(maximum).joined(separator: "\n")
        truncated = removedCount > maximum || addedCount > maximum
    }
}

public struct EditorDraft: Codable, Equatable {
    public let id: UUID
    public let hostID: UUID?
    public let connectionKey: String?
    public let path: String
    public let original: Data
    public let edited: Data
    public let updated: Date
    public init(hostID: UUID?, connectionKey: String?, path: String, original: Data, edited: Data) {
        id = UUID()
        self.hostID = hostID; self.connectionKey = connectionKey; self.path = path
        self.original = original; self.edited = edited; updated = Date()
    }
    public var isValid: Bool {
        original.count <= 512 * 1024 && edited.count <= 512 * 1024 && String(data: original, encoding: .utf8) != nil && String(data: edited, encoding: .utf8) != nil
    }
    public func canRestore(hostID: UUID?, connectionKey: String?, path: String, current: Data) -> Bool {
        isValid && self.hostID == hostID && self.connectionKey == connectionKey && self.path == path && original == current
    }
}
