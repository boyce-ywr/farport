import Foundation

public struct HostProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    public var port: Int
    public var username: String
    public var group: String
    public var identityFile: String
    public var jumpHost: String
    public var prefersTmux: Bool
    public var lastSession: String
    public var color: String
    public var configFile: String? = nil
    public var attachmentInsertion: AttachmentInsertionPolicy? = nil

    public init(id: UUID = UUID(), name: String = "", address: String = "", port: Int = 22,
                username: String = "", group: String = "我的主机", identityFile: String = "",
                jumpHost: String = "", prefersTmux: Bool = false, lastSession: String = "", color: String = "mint") {
        self.id = id; self.name = name; self.address = address; self.port = port
        self.username = username; self.group = group; self.identityFile = identityFile
        self.jumpHost = jumpHost; self.prefersTmux = prefersTmux; self.lastSession = lastSession; self.color = color
    }

    public var subtitle: String { "\(username.isEmpty ? "" : username + "@")\(address):\(port)" }
    public var connectionKey: String { [address, String(port), username, identityFile, jumpHost, configFile ?? ""].joined(separator: "\0") }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchError.message(L10n.text("请输入主机名称。")) }
        guard !address.isEmpty, !address.hasPrefix("-"),
              address.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !address.contains("@"), !address.contains("/") else { throw WorkbenchError.message(L10n.text("主机地址应为 IP、域名或 SSH 配置别名，不能包含空格、@ 或 /。")) }
        guard (1...65535).contains(port) else { throw WorkbenchError.message(L10n.text("端口必须在 1–65535 之间。")) }
        guard username.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !username.hasPrefix("-") else { throw WorkbenchError.message(L10n.text("用户名格式不正确。")) }
        guard !identityFile.contains("\0"), !identityFile.contains("\n"),
              !jumpHost.hasPrefix("-"), jumpHost.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw WorkbenchError.message(L10n.text("密钥路径或跳板机格式不正确。"))
        }
    }
}

public enum WorkbenchError: LocalizedError {
    case message(String)
    case cancelled
    case protocolViolation(String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return L10n.text("操作已暂停或取消。")
        case .protocolViolation(let text): return L10n.text("SFTP 协议错误：\(text)")
        }
    }
}

public struct FileAttributes: Codable, Hashable, Sendable {
    public var size: UInt64
    public var permissions: UInt32
    public var modified: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public init(size: UInt64 = 0, permissions: UInt32 = 0, modified: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0) {
        self.size = size; self.permissions = permissions; self.modified = modified; self.uid = uid; self.gid = gid
    }
    public var isDirectory: Bool { permissions & 0o170000 == 0o040000 }
    public var isRegularFile: Bool { permissions & 0o170000 == 0o100000 }
    public var isSymbolicLink: Bool { permissions & 0o170000 == 0o120000 }
    public var permissionText: String { String(format: "%03o", permissions & 0o777) }
    public var date: Date { Date(timeIntervalSince1970: Double(modified)) }
}

public struct RemoteFile: Identifiable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var attributes: FileAttributes
    public var id: String { path }
    public init(name: String, path: String, attributes: FileAttributes) { self.name = name; self.path = path; self.attributes = attributes }
}

public enum RemotePath {
    public static func join(_ parent: String, _ name: String) -> String { (parent == "/" ? "" : parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) .withLeadingSlash + "/" + name }
    public static func parent(_ path: String) -> String {
        let result = (path as NSString).deletingLastPathComponent
        return result.isEmpty ? "/" : result
    }
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && !name.contains("\n")
    }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

private extension String {
    var withLeadingSlash: String { isEmpty ? "" : "/" + self }
}

public struct TmuxSession: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var windows: Int
    public var attached: Int
    public var created: Date
    public init(id: String, name: String, windows: Int, attached: Int, created: Date) {
        self.id = id; self.name = name; self.windows = windows; self.attached = attached; self.created = created
    }
}

public struct TmuxPane: Identifiable, Sendable {
    public var id: String
    public var sessionID: String
    public var windowID: String
    public var windowName: String
    public var index: String
    public var command: String
    public var directory: String
    public var active: Bool
    public init(id: String, sessionID: String, windowID: String, windowName: String, index: String, command: String, directory: String, active: Bool) {
        self.id = id; self.sessionID = sessionID; self.windowID = windowID; self.windowName = windowName
        self.index = index; self.command = command; self.directory = directory; self.active = active
    }
}

public struct FileEndpoint: Codable, Hashable, Sendable {
    public var hostID: UUID?
    public var path: String
    public init(hostID: UUID? = nil, path: String) { self.hostID = hostID; self.path = path }
    public var isLocal: Bool { hostID == nil }
}

public enum TransferStatus: String, Codable, Sendable {
    case queued, running, paused, awaitingConfirmation, completed, failed, cancelled
    public var canClearRecord: Bool { [.completed, .failed, .cancelled].contains(self) }
    public var title: String {
        switch self {
        case .queued: return L10n.text("等待中")
        case .running: return L10n.text("传输中")
        case .paused: return L10n.text("已暂停")
        case .awaitingConfirmation: return L10n.text("等待覆盖确认")
        case .completed: return L10n.text("已完成")
        case .failed: return L10n.text("传输失败")
        case .cancelled: return L10n.text("已取消")
        }
    }
}

public enum ForwardingKind: String, Sendable {
    case local, remote, dynamic
}

public struct TransferEntry: Codable, Sendable {
    public var relativePath: String
    public var attributes: FileAttributes
    public var finished: Bool = false
    public var createdDirectory: Bool? = nil
    public init(relativePath: String, attributes: FileAttributes) { self.relativePath = relativePath; self.attributes = attributes }
}

public struct TransferJob: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var source: FileEndpoint
    public var destination: FileEndpoint
    public var status: TransferStatus = .queued
    public var totalBytes: UInt64 = 0
    public var completedBytes: UInt64 = 0
    public var entries: [TransferEntry] = []
    public var message: String = ""
    public var created: Date = Date()
    public var overwrite: Bool = false
    public var conflicts: [TransferConflict]?
    public var approvedConflicts: [TransferConflict]?
    public init(source: FileEndpoint, destination: FileEndpoint, overwrite: Bool = false) {
        self.source = source; self.destination = destination; self.overwrite = overwrite
    }
    public var name: String { (source.path as NSString).lastPathComponent }
    public var fraction: Double { totalBytes == 0 ? (status == .completed ? 1 : 0) : min(1, Double(completedBytes) / Double(totalBytes)) }
}

public struct TransferConflict: Codable, Sendable, Equatable {
    public var path: String
    public var existing: FileAttributes
    public var incoming: FileAttributes
    public var canReplace: Bool { (existing.isRegularFile && incoming.isRegularFile) || (existing.isDirectory && incoming.isDirectory) }
    public init(path: String, existing: FileAttributes, incoming: FileAttributes) { self.path = path; self.existing = existing; self.incoming = incoming }
}

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled { throw WorkbenchError.cancelled } }
}
