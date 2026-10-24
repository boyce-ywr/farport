import Foundation

public enum FileTransferOperation: String, Codable, Sendable {
    case copy, move
}

public extension FileEndpoint {
    func isSameMachine(as other: FileEndpoint, hosts: [HostProfile]) -> Bool {
        if isLocal || other.isLocal { return isLocal && other.isLocal }
        guard let source = hosts.first(where: { $0.id == hostID }),
              let destination = hosts.first(where: { $0.id == other.hostID }) else { return false }
        return source.connectionKey == destination.connectionKey
    }
}
