import Foundation
import WorkbenchCore

extension TransferEngine {
    func privateStagingDirectory(_ path: String, filesystem: EndpointFileSystem) throws {
        if let existing = try filesystem.stat(path) {
            guard existing.isDirectory, !existing.isSymbolicLink, existing.permissions & 0o077 == 0 else { throw WorkbenchError.message(L10n.text("文件暂存目录不安全，未继续操作。")) }
        } else { _ = try filesystem.mkdir(path) }
    }
    func copyNativeFile(_ source: String, to destination: String, attributes: FileAttributes, job: TransferJob, filesystem: EndpointFileSystem, hosts: [HostProfile], cancellation: CancellationFlag) throws {
        let directory = RemotePath.join(RemotePath.parent(destination), ".swb-" + job.id.uuidString + ".copy")
        let temporary = RemotePath.join(directory, "payload")
        try privateStagingDirectory(directory, filesystem: filesystem)
        if let existing = try filesystem.stat(temporary), !existing.isRegularFile || existing.isSymbolicLink {
            throw WorkbenchError.message(L10n.text("断点文件无效，未继续写入。"))
        }
        try runNative("cp", arguments: ["-p", "-P", "-f", source, temporary], hostID: job.source.hostID, hosts: hosts, cancellation: cancellation)
        guard let original = try filesystem.stat(source), matches(original, attributes),
              let copied = try filesystem.stat(temporary), matches(copied, attributes) else {
            throw WorkbenchError.message(L10n.text("源文件在传输期间变化；保留断点，未替换目标。"))
        }
        try cancellation.check()
        let replace = try mayReplace(destination, incoming: attributes, job: job, filesystem: filesystem)
        try filesystem.finalize(temporary, destination: destination, attributes: attributes, overwrite: replace)
        try? filesystem.remove(directory, directory: true)
    }
    func runNative(_ command: String, arguments: [String], hostID: UUID?, hosts: [HostProfile], cancellation: CancellationFlag) throws {
        let result: CommandResult
        if let hostID {
            guard let host = hosts.first(where: { $0.id == hostID }) else { throw WorkbenchError.message(L10n.text("传输关联的主机已被移除。")) }
            let script = "command " + command + " " + arguments.map(RemotePath.quote).joined(separator: " ")
            result = try transport.run(host, command: "/bin/sh -c " + RemotePath.quote(script), cancellation: cancellation, timeout: 3600)
        } else {
            result = try ProcessRunner.run(executable: "/bin/" + command, arguments: arguments, cancellation: cancellation, timeout: 3600)
        }
        _ = try result.checked()
    }
    func matches(_ current: FileAttributes, _ expected: FileAttributes) -> Bool {
        !current.isSymbolicLink && current.isDirectory == expected.isDirectory && current.isRegularFile == expected.isRegularFile
            && (current.isDirectory || (current.size == expected.size && current.modified == expected.modified))
    }
    func mayReplace(_ path: String, incoming: FileAttributes, job: TransferJob, filesystem: EndpointFileSystem) throws -> Bool {
        guard let existing = try filesystem.stat(path) else { return false }
        if job.nativeMove == true, existing.isDirectory, incoming.isDirectory {
            throw WorkbenchError.message(L10n.text("移动目标新出现了目录；请移开该目录后从原任务继续，暂存文件不会被删除。"))
        }
        let conflict = TransferConflict(path: path, existing: existing, incoming: incoming)
        guard existing.isRegularFile, incoming.isRegularFile, job.overwrite || job.approvedConflicts?.contains(conflict) == true else { throw Conflicts(items: [conflict]) }
        return true
    }
    func nativeMoveDirectory(_ job: TransferJob) -> String {
        RemotePath.join(RemotePath.parent(job.destination.path), ".swb-" + job.id.uuidString + ".move")
    }
    func finishNativeMove(_ job: inout TransferJob, filesystem: EndpointFileSystem, hosts: [HostProfile], cancellation: CancellationFlag, update: (TransferJob) -> Void) throws {
        let directory = nativeMoveDirectory(job)
        let payload = RemotePath.join(directory, "payload")
        job.message = L10n.text("同机原生 mv · 暂存后安全落位，暂停后请从此任务继续"); update(job)
        try cancellation.check()
        try privateStagingDirectory(directory, filesystem: filesystem)
        if try filesystem.stat(payload) == nil {
            try verifyManifest(job.entries, filesystem: filesystem, root: job.source.path, cancellation: cancellation)
            guard let root = job.entries.first else { throw WorkbenchError.message(L10n.text("源文件不存在。")) }
            _ = try mayReplace(job.destination.path, incoming: root.attributes, job: job, filesystem: filesystem)
            try runNative("mv", arguments: ["-n", job.source.path, payload], hostID: job.source.hostID, hosts: hosts, cancellation: cancellation)
        }
        try cancellation.check()
        guard try filesystem.stat(job.source.path) == nil else {
            throw WorkbenchError.message(L10n.text("源和移动暂存同时存在，请先检查两处文件；不会自动删除任何一处。"))
        }
        try verifyManifest(job.entries, filesystem: filesystem, root: payload, cancellation: cancellation)
        guard let root = job.entries.first else { throw WorkbenchError.message(L10n.text("源文件不存在。")) }
        let replace = try mayReplace(job.destination.path, incoming: root.attributes, job: job, filesystem: filesystem)
        try filesystem.finalize(payload, destination: job.destination.path, attributes: root.attributes, overwrite: replace)
        for index in job.entries.indices { job.entries[index].finished = true; job.entries[index].sourceRemoved = true }
        job.status = .completed; job.completedBytes = job.totalBytes
        job.message = L10n.text("移动完成 · 同机原生 mv，文件内容未经过 Mac 中转")
        try? filesystem.remove(directory, directory: true)
    }
    func verifyManifest(_ entries: [TransferEntry], filesystem: EndpointFileSystem, root: String, cancellation: CancellationFlag) throws {
        var current: [TransferEntry] = []
        try scan(filesystem, root: root, relative: "", entries: &current, cancellation: cancellation)
        let expected = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.attributes) })
        guard current.count == expected.count, current.allSatisfy({ entry in expected[entry.relativePath].map { matches(entry.attributes, $0) } == true }) else {
            throw WorkbenchError.message(L10n.text("移动期间文件或目录内容发生变化，已停止删源；请保留源和目标。"))
        }
    }
    func verifyContent(_ entry: TransferEntry, sourcePath: String, targetPath: String, source: EndpointFileSystem, destination: EndpointFileSystem, cancellation: CancellationFlag) throws {
        guard let original = try source.stat(sourcePath), matches(original, entry.attributes),
              let copied = try destination.stat(targetPath), matches(copied, entry.attributes) else {
            throw WorkbenchError.message(L10n.text("移动期间文件或目录内容发生变化，已停止删源；请保留源和目标。"))
        }
        if entry.attributes.isDirectory { return }
        let reader = try source.open(sourcePath, writing: false); defer { try? source.close(reader) }
        let target = try destination.open(targetPath, writing: false); defer { try? destination.close(target) }
        var offset: UInt64 = 0
        while offset < entry.attributes.size {
            try cancellation.check()
            let count = Int(min(UInt64(2 * 1024 * 1024), entry.attributes.size - offset))
            let original = try source.read(reader, offset: offset, length: count)
            let copied = try destination.read(target, offset: offset, length: count)
            guard original.count == count, original == copied else { throw WorkbenchError.message(L10n.text("移动内容校验失败，源文件未删除。")) }
            offset += UInt64(count)
        }
        guard let original = try source.stat(sourcePath), matches(original, entry.attributes),
              let copied = try destination.stat(targetPath), matches(copied, entry.attributes) else {
            throw WorkbenchError.message(L10n.text("移动期间文件或目录内容发生变化，已停止删源；请保留源和目标。"))
        }
    }
    func removeVerifiedSources(_ job: inout TransferJob, source: EndpointFileSystem, destination: EndpointFileSystem, cancellation: CancellationFlag, update: (TransferJob) -> Void) throws {
        let remaining = job.entries.filter { $0.sourceRemoved != true }
        if remaining.isEmpty { return }
        job.message = L10n.text("正在校验移动内容；校验通过后才删除源条目"); update(job)
        try verifyManifest(remaining, filesystem: source, root: job.source.path, cancellation: cancellation)
        for entry in remaining {
            let sourcePath = entry.relativePath.isEmpty ? job.source.path : RemotePath.join(job.source.path, entry.relativePath)
            let targetPath = entry.relativePath.isEmpty ? job.destination.path : RemotePath.join(job.destination.path, entry.relativePath)
            try verifyContent(entry, sourcePath: sourcePath, targetPath: targetPath, source: source, destination: destination, cancellation: cancellation)
        }
        job.message = L10n.text("移动内容校验通过，正在删除已核对的源条目"); update(job)
        for index in job.entries.indices.reversed() where job.entries[index].sourceRemoved != true {
            try cancellation.check()
            let entry = job.entries[index]
            let sourcePath = entry.relativePath.isEmpty ? job.source.path : RemotePath.join(job.source.path, entry.relativePath)
            let targetPath = entry.relativePath.isEmpty ? job.destination.path : RemotePath.join(job.destination.path, entry.relativePath)
            try verifyContent(entry, sourcePath: sourcePath, targetPath: targetPath, source: source, destination: destination, cancellation: cancellation)
            try cancellation.check()
            try source.remove(sourcePath, directory: entry.attributes.isDirectory)
            job.entries[index].sourceRemoved = true; update(job)
        }
    }
}
