import Foundation

public struct AttachmentDeliveryIdentity: Equatable, Sendable {
    public let sessionID: UUID
    public let connectionID: UUID
    public let focusGeneration: UInt64
    public let inputGeneration: UInt64
    public let windowNumber: Int?
    public let applicationActive: Bool
    public init(sessionID: UUID, connectionID: UUID, focusGeneration: UInt64, inputGeneration: UInt64, windowNumber: Int? = nil, applicationActive: Bool = true) {
        self.sessionID = sessionID; self.connectionID = connectionID; self.focusGeneration = focusGeneration; self.inputGeneration = inputGeneration
        self.windowNumber = windowNumber; self.applicationActive = applicationActive
    }
}

public enum AttachmentReference {
    public static func text(paths: [String]) throws -> String {
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw WorkbenchError.message(L10n.text("附件路径无效，未向终端插入。"))
        }
        return paths.map(RemotePath.quote).joined(separator: " ") + " "
    }
}
