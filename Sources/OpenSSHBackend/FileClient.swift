import Foundation
import Darwin
import WorkbenchCore

public protocol FileClient: AnyObject {
    func close()
    func realpath(_ path: String) throws -> String
    func list(_ path: String) throws -> [RemoteFile]
    func stat(_ path: String, followLinks: Bool) throws -> FileAttributes
    func preview(_ path: String, offset: UInt64, limit: Int) throws -> Data
    func createFile(_ path: String) throws
    func mkdir(_ path: String, permissions: UInt32) throws
    func rename(_ source: String, to destination: String, overwrite: Bool) throws
    func chmod(_ path: String, permissions: UInt32) throws
    func removeRecursively(_ path: String, depth: Int) throws
    func saveText(_ path: String, data: Data, expected: FileAttributes, original: Data?) throws
}

public extension FileClient {
    func realpath() throws -> String { try realpath(".") }
    func stat(_ path: String) throws -> FileAttributes { try stat(path, followLinks: false) }
    func preview(_ path: String) throws -> Data { try preview(path, offset: 0, limit: 512 * 1024) }
    func mkdir(_ path: String) throws { try mkdir(path, permissions: 0o755) }
    func rename(_ source: String, to destination: String) throws { try rename(source, to: destination, overwrite: false) }
    func removeRecursively(_ path: String) throws { try removeRecursively(path, depth: 0) }
}

extension SFTPClient: FileClient {
    public func createFile(_ path: String) throws { let handle = try openWrite(path, exclusive: true); try closeHandle(handle) }
}

public final class LocalFileClient: FileClient {
    private let cancellation: CancellationFlag
    public init(cancellation: CancellationFlag = CancellationFlag()) { self.cancellation = cancellation }
    public func close() {}
    public func realpath(_ path: String) throws -> String {
        try cancellation.check()
        let input = path == "." ? FileManager.default.homeDirectoryForCurrentUser.path : NSString(string: path).expandingTildeInPath
        let resolved = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath().path
        guard try stat(resolved, followLinks: true).isDirectory else { throw WorkbenchError.message(L10n.text("所选本地路径不是目录。")) }
        return resolved
    }
    public func stat(_ path: String, followLinks: Bool = false) throws -> FileAttributes {
        try cancellation.check()
        let resolved = followLinks ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : path
        let values = try FileManager.default.attributesOfItem(atPath: resolved)
        let type = values[.type] as? FileAttributeType
        let bits: UInt32 = type == .typeDirectory ? 0o040000 : (type == .typeSymbolicLink ? 0o120000 : (type == .typeRegular ? 0o100000 : 0))
        let date = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileAttributes(size: (values[.size] as? NSNumber)?.uint64Value ?? 0,
                              permissions: bits | ((values[.posixPermissions] as? NSNumber)?.uint32Value ?? 0),
                              modified: UInt32(clamping: Int64(date)), uid: (values[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0,
                              gid: (values[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0)
    }
    public func list(_ path: String) throws -> [RemoteFile] {
        try FileManager.default.contentsOfDirectory(atPath: path).map { name in
            let child = RemotePath.join(path, name)
            return RemoteFile(name: name, path: child, attributes: try stat(child))
        }.sorted { left, right in
            left.attributes.isDirectory != right.attributes.isDirectory ? left.attributes.isDirectory : left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
    public func preview(_ path: String, offset: UInt64 = 0, limit: Int = 512 * 1024) throws -> Data {
        guard try stat(path, followLinks: true).isRegularFile else { throw WorkbenchError.message(L10n.text("只预览普通文件。")) }
        guard limit >= 0, limit <= 8 * 1024 * 1024 else { throw WorkbenchError.message(L10n.text("预览长度超限。")) }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        try handle.seek(toOffset: offset); try cancellation.check()
        return try handle.read(upToCount: limit) ?? Data()
    }
    public func createFile(_ path: String) throws {
        try cancellation.check()
        let descriptor = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WorkbenchError.message(L10n.text("无法创建文件：\(String(cString: strerror(errno)))")) }
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).close()
    }
    public func mkdir(_ path: String, permissions: UInt32 = 0o755) throws {
        try cancellation.check()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: permissions & 0o777])
    }
    public func rename(_ source: String, to destination: String, overwrite: Bool = false) throws {
        try cancellation.check()
        let result = overwrite ? Darwin.rename(source, destination) : renamex_np(source, destination, UInt32(RENAME_EXCL))
        guard result == 0 else { throw WorkbenchError.message(L10n.text("重命名失败，未覆盖现有文件：\(String(cString: strerror(errno)))")) }
    }
    public func chmod(_ path: String, permissions: UInt32) throws {
        try cancellation.check(); try FileManager.default.setAttributes([.posixPermissions: permissions & 0o777], ofItemAtPath: path)
    }
    public func removeRecursively(_ path: String, depth: Int = 0) throws {
        try cancellation.check()
        guard !path.isEmpty, URL(fileURLWithPath: path).standardizedFileURL.path != "/" else { throw WorkbenchError.message(L10n.text("拒绝删除根目录。")) }
        try FileManager.default.removeItem(atPath: path)
    }
    public func saveText(_ path: String, data: Data, expected: FileAttributes, original: Data? = nil) throws {
        func validate() throws {
            let current = try stat(path)
            guard current.isRegularFile, current.size == expected.size, current.modified == expected.modified else { throw WorkbenchError.message(L10n.text("文件已发生变化，请重新读取。")) }
            if let original, try preview(path, limit: original.count + 1) != original { throw WorkbenchError.message(L10n.text("文件内容已发生变化，未覆盖。")) }
        }
        try validate()
        let temporary = path + ".swb-edit-" + UUID().uuidString
        try createFile(temporary)
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: temporary)); defer { try? handle.close() }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        try chmod(temporary, permissions: expected.permissions); try validate(); try rename(temporary, to: path, overwrite: true)
    }
}

public extension SSHTransport {
    func files(_ host: HostProfile?, cancellation: CancellationFlag = CancellationFlag()) throws -> any FileClient {
        if let host { return try sftp(host, cancellation: cancellation) }
        return LocalFileClient(cancellation: cancellation)
    }
}
