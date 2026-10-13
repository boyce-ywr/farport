import Foundation

enum FileBrowserSource: Hashable {
    case terminal(UUID)
    case host(UUID)
    case local

    var terminalID: UUID? {
        if case .terminal(let identifier) = self { return identifier }
        return nil
    }
}
