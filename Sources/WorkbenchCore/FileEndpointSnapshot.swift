import Foundation

public struct FileEndpointSnapshot: Sendable {
    public let id = UUID()
    public let endpoints: [FileEndpoint]
    public let operation: FileTransferOperation
    private let connections: [UUID: String]

    public init(endpoints: [FileEndpoint], hosts: [HostProfile], operation: FileTransferOperation = .copy) throws {
        guard !endpoints.isEmpty, endpoints.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\0") }) else {
            throw WorkbenchError.message(L10n.text("请选择有效的文件或目录。"))
        }
        var connections: [UUID: String] = [:]
        for identifier in Set(endpoints.compactMap(\.hostID)) {
            guard let host = hosts.first(where: { $0.id == identifier }) else {
                throw WorkbenchError.message(L10n.text("文件所属主机已移除，请重新选择文件。"))
            }
            connections[identifier] = host.connectionKey
        }
        self.endpoints = endpoints; self.connections = connections; self.operation = operation
    }
    public func validate(hosts: [HostProfile]) throws {
        for (identifier, connection) in connections {
            guard hosts.contains(where: { $0.id == identifier && $0.connectionKey == connection }) else {
                throw WorkbenchError.message(L10n.text("文件来源或目标主机配置已变化，请重新复制或拖拽。"))
            }
        }
    }
}
