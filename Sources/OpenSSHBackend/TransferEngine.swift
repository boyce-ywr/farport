import Foundation
import Darwin
import WorkbenchCore

private enum EndpointHandle {
    case local(FileHandle)
    case remote(Data)
}

private final class EndpointFileSystem {
    let remote: SFTPClient?
    init(endpoint: FileEndpoint, hosts: [HostProfile], transport: SSHTransport, cancellation: CancellationFlag) throws {
        if let identifier = endpoint.hostID {
            guard let host = hosts.first(where: { $0.id == identifier }) else { throw WorkbenchError.message(L10n.text("传输关联的主机已被移除。")) }
            remote = try transport.sftp(host, cancellation: cancellation)
        } else { remote = nil }
    }
    func stat(_ path: String) throws -> FileAttributes? {
        if let remote { return try remote.statIfExists(path) }
        do {
            return try LocalFileClient().stat(path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return nil }
    }
    func list(_ path: String) throws -> [RemoteFile] {
        if let remote { return try remote.list(path) }
        return try FileManager.default.contentsOfDirectory(atPath: path).sorted().map { name in
            let child = RemotePath.join(path, name)
            guard let attributes = try stat(child) else { throw WorkbenchError.message(L10n.text("扫描期间文件消失：\(name)")) }
            return RemoteFile(name: name, path: child, attributes: attributes)
        }
    }
    func mkdir(_ path: String) throws -> Bool {
        if let existing = try stat(path) {
            guard existing.isDirectory else { throw WorkbenchError.message(L10n.text("目标路径不是目录：\((path as NSString).lastPathComponent)")) }; return false
        }
        if let remote { try remote.mkdir(path, permissions: 0o700) }
        else { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        return true
    }
    func setAttributes(_ path: String, attributes: FileAttributes) throws {
        if let remote { try remote.chmod(path, permissions: attributes.permissions); try remote.setModified(path, modified: attributes.modified) }
        else { try FileManager.default.setAttributes([.posixPermissions: attributes.permissions & 0o777, .modificationDate: attributes.date], ofItemAtPath: path) }
    }
    func open(_ path: String, writing: Bool, exclusive: Bool = false) throws -> EndpointHandle {
        if let remote { return .remote(try writing ? remote.openWrite(path, exclusive: exclusive) : remote.openRead(path)) }
        let flags = (writing ? O_WRONLY | O_CREAT : O_RDONLY) | O_NOFOLLOW | (exclusive ? O_EXCL : 0)
        let descriptor = Darwin.open(path, flags, 0o600)
        guard descriptor >= 0 else { throw WorkbenchError.message(L10n.text("无法打开本地文件：\(String(cString: strerror(errno)))")) }
        return .local(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }
    func close(_ handle: EndpointHandle) throws {
        switch handle { case .local(let file): try file.close(); case .remote(let value): try remote?.closeHandle(value) }
    }
    func read(_ handle: EndpointHandle, offset: UInt64, length: Int) throws -> Data {
        switch handle {
        case .local(let file): try file.seek(toOffset: offset); return try file.read(upToCount: length) ?? Data()
        case .remote(let value): return try remote!.read(value, offset: offset, length: length)
        }
    }
    func write(_ handle: EndpointHandle, offset: UInt64, data: Data) throws {
        switch handle {
        case .local(let file): try file.seek(toOffset: offset); try file.write(contentsOf: data)
        case .remote(let value): try remote!.write(value, offset: offset, data: data)
        }
    }
    func sync(_ handle: EndpointHandle) throws {
        switch handle { case .local(let file): try file.synchronize(); case .remote(let value): try remote?.sync(value) }
    }
    func finalize(_ temporary: String, destination: String, attributes: FileAttributes, overwrite: Bool) throws {
        if let remote {
            try remote.chmod(temporary, permissions: attributes.permissions)
            try remote.setModified(temporary, modified: attributes.modified)
            try remote.rename(temporary, to: destination, overwrite: overwrite)
        } else {
            try FileManager.default.setAttributes([.posixPermissions: attributes.permissions & 0o777, .modificationDate: attributes.date], ofItemAtPath: temporary)
            if overwrite {
                guard Darwin.rename(temporary, destination) == 0 else { throw WorkbenchError.message(L10n.text("本地原子替换失败：\(String(cString: strerror(errno)))")) }
            } else {
                guard renamex_np(temporary, destination, UInt32(RENAME_EXCL)) == 0 else { throw WorkbenchError.message(L10n.text("目标文件已存在或无法完成重命名，未覆盖原文件。")) }
            }
        }
    }
}

public final class TransferEngine: @unchecked Sendable {
    private struct Conflicts: Error { let items: [TransferConflict] }
    public let transport: SSHTransport
    public init(transport: SSHTransport) { self.transport = transport }

    public func execute(_ initial: TransferJob, hosts: [HostProfile], cancellation: CancellationFlag,
                        update: @escaping (TransferJob) -> Void) -> TransferJob {
        var job = initial; job.status = .running; job.message = L10n.text("正在连接并检查文件…"); update(job)
        do {
            guard job.source != job.destination else { throw WorkbenchError.message(L10n.text("源路径和目标路径不能相同。")) }
            if job.source.hostID == job.destination.hostID,
               job.destination.path.hasPrefix(job.source.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) .withSlash + "/") {
                throw WorkbenchError.message(L10n.text("不能把目录复制到它自身的子目录。"))
            }
            let source = try EndpointFileSystem(endpoint: job.source, hosts: hosts, transport: transport, cancellation: cancellation)
            let destination = try EndpointFileSystem(endpoint: job.destination, hosts: hosts, transport: transport, cancellation: cancellation)
            if job.entries.isEmpty {
                var manifest: [TransferEntry] = []
                try scan(source, root: job.source.path, relative: "", entries: &manifest, cancellation: cancellation)
                job.entries = manifest
                job.totalBytes = job.entries.filter { !$0.attributes.isDirectory }.reduce(0) { $0 + $1.attributes.size }
            }
            job.completedBytes = job.entries.filter { $0.finished && !$0.attributes.isDirectory }.reduce(0) { $0 + $1.attributes.size }
            var conflicts: [TransferConflict] = []
            var incompatiblePaths: [String] = []
            for entry in job.entries where !entry.finished {
                try cancellation.check()
                let targetPath = entry.relativePath.isEmpty ? job.destination.path : RemotePath.join(job.destination.path, entry.relativePath)
                if incompatiblePaths.contains(where: { targetPath.hasPrefix($0 + "/") }) { continue }
                if let existing = try destination.stat(targetPath) {
                    let conflict = TransferConflict(path: targetPath, existing: existing, incoming: entry.attributes)
                    if !conflict.canReplace || (!job.overwrite && job.approvedConflicts?.contains(conflict) != true) { conflicts.append(conflict) }
                    if !conflict.canReplace { incompatiblePaths.append(targetPath) }
                }
            }
            if !conflicts.isEmpty { throw Conflicts(items: conflicts) }
            job.conflicts = nil
            job.message = L10n.text("\(job.entries.count) 个条目 · 流式中转"); update(job)
            var lastUpdate = Date.distantPast
            for index in job.entries.indices {
                try cancellation.check()
                let entry = job.entries[index]
                let sourcePath = entry.relativePath.isEmpty ? job.source.path : RemotePath.join(job.source.path, entry.relativePath)
                let targetPath = entry.relativePath.isEmpty ? job.destination.path : RemotePath.join(job.destination.path, entry.relativePath)
                guard let current = try source.stat(sourcePath), current.isDirectory == entry.attributes.isDirectory,
                      current.isDirectory || (current.size == entry.attributes.size && current.modified == entry.attributes.modified),
                      !current.isSymbolicLink else { throw WorkbenchError.message(L10n.text("源文件已发生变化，不能沿用旧断点。请新建传输任务：\((sourcePath as NSString).lastPathComponent)")) }
                if entry.attributes.isDirectory {
                    if let existing = try destination.stat(targetPath) {
                        let conflict = TransferConflict(path: targetPath, existing: existing, incoming: entry.attributes)
                        if !conflict.canReplace || (!entry.finished && !job.overwrite && job.approvedConflicts?.contains(conflict) != true) { throw Conflicts(items: [conflict]) }
                    }
                    if try destination.mkdir(targetPath) { job.entries[index].createdDirectory = true }
                    job.entries[index].finished = true; continue
                }
                if entry.finished {
                    guard let finished = try destination.stat(targetPath), finished.size == entry.attributes.size,
                          finished.modified == entry.attributes.modified else { throw WorkbenchError.message(L10n.text("已完成的目标文件被修改或删除，请重新创建任务。")) }
                    continue
                }
                if let existing = try destination.stat(targetPath) {
                    let conflict = TransferConflict(path: targetPath, existing: existing, incoming: entry.attributes)
                    if !existing.isRegularFile || (!job.overwrite && job.approvedConflicts?.contains(conflict) != true) { throw Conflicts(items: [conflict]) }
                }
                let temporary = targetPath + ".swb-" + job.id.uuidString + ".part"
                let partial = try destination.stat(temporary)
                guard partial == nil || (!partial!.isDirectory && !partial!.isSymbolicLink && partial!.size <= entry.attributes.size) else { throw WorkbenchError.message(L10n.text("断点文件无效，未继续写入。")) }
                var offset = partial?.size ?? 0
                let reader = try source.open(sourcePath, writing: false)
                defer { try? source.close(reader) }
                if offset > 0 {
                    job.message = L10n.text("正在校验已有断点…"); update(job)
                    let partialReader = try destination.open(temporary, writing: false)
                    defer { try? destination.close(partialReader) }
                    var verified: UInt64 = 0
                    while verified < offset {
                        try cancellation.check()
                        let count = Int(min(UInt64(2 * 1024 * 1024), offset - verified))
                        let expected = try source.read(reader, offset: verified, length: count)
                        let actual = try destination.read(partialReader, offset: verified, length: count)
                        guard !expected.isEmpty, expected == actual else { throw WorkbenchError.message(L10n.text("断点内容与源文件不一致，已停止以避免生成损坏文件。")) }
                        verified += UInt64(expected.count)
                    }
                }
                let writer = try destination.open(temporary, writing: true, exclusive: partial == nil)
                defer { try? destination.close(writer) }
                job.completedBytes += offset
                while offset < entry.attributes.size {
                    try cancellation.check()
                    let count = Int(min(UInt64(2 * 1024 * 1024), entry.attributes.size - offset))
                    let data = try source.read(reader, offset: offset, length: count)
                    guard !data.isEmpty else { throw WorkbenchError.message(L10n.text("源文件提前结束，未完成目标文件。")) }
                    try destination.write(writer, offset: offset, data: data)
                    offset += UInt64(data.count); job.completedBytes += UInt64(data.count)
                    if Date().timeIntervalSince(lastUpdate) > 0.2 {
                        job.message = "\((targetPath as NSString).lastPathComponent) · \(index + 1)/\(job.entries.count)"; update(job); lastUpdate = Date()
                    }
                }
                try destination.sync(writer)
                guard let after = try source.stat(sourcePath), after.size == entry.attributes.size, after.modified == entry.attributes.modified else { throw WorkbenchError.message(L10n.text("源文件在传输期间变化；保留断点，未替换目标。")) }
                try destination.close(writer)
                try cancellation.check()
                var mayReplace = false
                if let existing = try destination.stat(targetPath) {
                    let conflict = TransferConflict(path: targetPath, existing: existing, incoming: entry.attributes)
                    guard existing.isRegularFile, job.overwrite || job.approvedConflicts?.contains(conflict) == true else { throw Conflicts(items: [conflict]) }
                    mayReplace = true
                }
                do { try destination.finalize(temporary, destination: targetPath, attributes: entry.attributes, overwrite: mayReplace) }
                catch {
                    if !mayReplace, let existing = try destination.stat(targetPath) { throw Conflicts(items: [TransferConflict(path: targetPath, existing: existing, incoming: entry.attributes)]) }
                    throw error
                }
                job.entries[index].finished = true
            }
            for entry in job.entries.reversed() where entry.attributes.isDirectory && entry.createdDirectory == true {
                let targetPath = entry.relativePath.isEmpty ? job.destination.path : RemotePath.join(job.destination.path, entry.relativePath)
                try destination.setAttributes(targetPath, attributes: entry.attributes)
            }
            job.status = .completed; job.completedBytes = job.totalBytes
            job.message = !job.source.isLocal && !job.destination.isLocal ? L10n.text("传输完成 · 未将远端文件缓存至 Mac 磁盘") : L10n.text("传输完成 · 已写入目标位置")
        } catch let conflict as Conflicts {
            job.status = cancellation.isCancelled ? .paused : .awaitingConfirmation
            job.conflicts = conflict.items
            job.message = L10n.text("目标已存在：\(conflict.items.count) 项等待确认，尚未覆盖。")
        } catch {
            job.status = cancellation.isCancelled ? .paused : .failed
            job.message = cancellation.isCancelled ? L10n.text("已保留断点；恢复时校验已有内容后继续。") : error.localizedDescription
        }
        update(job); return job
    }
    private func scan(_ filesystem: EndpointFileSystem, root: String, relative: String,
                      entries: inout [TransferEntry], cancellation: CancellationFlag, depth: Int = 0) throws {
        try cancellation.check()
        guard depth < 128, entries.count < 100_000 else { throw WorkbenchError.message(L10n.text("目录树过深或超过十万项，请分批传输。")) }
        let path = relative.isEmpty ? root : RemotePath.join(root, relative)
        guard let attributes = try filesystem.stat(path) else { throw WorkbenchError.message(L10n.text("源文件不存在。")) }
        guard !attributes.isSymbolicLink else { throw WorkbenchError.message(L10n.text("不会自动跟随符号链接，请选择真实文件：\((path as NSString).lastPathComponent)")) }
        guard attributes.isDirectory || attributes.isRegularFile else { throw WorkbenchError.message(L10n.text("设备、管道和套接字不是普通文件，不能复制。")) }
        entries.append(TransferEntry(relativePath: relative, attributes: attributes))
        if attributes.isDirectory {
            for child in try filesystem.list(path) {
                let childRelative = relative.isEmpty ? child.name : relative + "/" + child.name
                try scan(filesystem, root: root, relative: childRelative, entries: &entries, cancellation: cancellation, depth: depth + 1)
            }
        }
    }
}

private extension String {
    var withSlash: String { "/" + self }
}
