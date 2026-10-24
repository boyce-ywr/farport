import Foundation
import CryptoKit
import WorkbenchCore

public struct UploadedAttachments: Sendable {
    public let directory: String
    public let paths: [String]
    public let fileCount: Int
}

public final class AttachmentUploader: @unchecked Sendable {
    public let transport: SSHTransport
    public init(transport: SSHTransport) { self.transport = transport }
    private static let cacheLock = NSLock()
    private static var temporaryRoots: [String: String] = [:]
    private static func cacheKey(_ host: HostProfile?) -> String { host?.id.uuidString ?? "local" }
    public static func forgetTemporaryDirectory(for host: HostProfile?) {
        let key = cacheKey(host)
        cacheLock.withLock { _ = temporaryRoots.removeValue(forKey: key) }
    }
    public func temporaryDirectory(host: HostProfile?, cancellation: CancellationFlag = CancellationFlag()) throws -> String {
        let key = Self.cacheKey(host)
        if let cached = Self.cacheLock.withLock({ Self.temporaryRoots[key] }) { return cached }
        let location: String
        if let host {
            location = try transport.run(host, command: "printf '%s' \"${TMPDIR:-/tmp}\"", cancellation: cancellation).checked().text
        } else { location = FileManager.default.temporaryDirectory.path }
        guard location.hasPrefix("/"), location.rangeOfCharacter(from: .controlCharacters) == nil else { throw WorkbenchError.message(L10n.text("无法确定目标机器的临时目录，未上传附件。")) }
        let client = try transport.files(host, cancellation: cancellation); defer { client.close() }
        let resolved = try client.realpath(location)
        Self.cacheLock.withLock { Self.temporaryRoots[key] = resolved }
        return resolved
    }
    public func upload(_ files: [URL], host: HostProfile?, directory: String, cancellation: CancellationFlag,
                       progress: @escaping (String, Double) -> Void) throws -> UploadedAttachments {
        try cancellation.check()
        guard !files.isEmpty, files.count <= 100, directory.hasPrefix("/"), directory.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WorkbenchError.message(L10n.text("请选择 1–100 个附件及目标机器上的绝对目录。"))
        }
        let local = LocalFileClient(cancellation: cancellation)
        let target = try transport.files(host, cancellation: cancellation); defer { target.close() }
        let canonical: String
        do { canonical = try target.realpath(directory) }
        catch { Self.forgetTemporaryDirectory(for: host); throw error }
        let batchDirectory = RemotePath.join(canonical, ".farport-attachments-" + UUID().uuidString.lowercased())
        do { try target.mkdir(batchDirectory, permissions: 0o700) }
        catch { Self.forgetTemporaryDirectory(for: host); throw error }
        let sources = files.map { FileEndpoint(path: $0.standardizedFileURL.path) }
        let jobs = try TransferBatch.jobs(sources: sources, destinationDirectory: FileEndpoint(hostID: host?.id, path: batchDirectory))
        let profiles = host.map { [$0] } ?? []
        var fileCount = 0
        for (index, job) in jobs.enumerated() {
            try cancellation.check()
            let result = TransferEngine(transport: transport).execute(job, hosts: profiles, cancellation: cancellation) { value in
                progress(L10n.text("上传 \(index + 1)/\(jobs.count)：\(job.name)"), (Double(index) + value.fraction * 0.8) / Double(jobs.count))
            }
            try cancellation.check()
            guard result.status == .completed else { throw WorkbenchError.message(L10n.text("附件上传未完成，未插入任何路径。\(result.message)\n目标暂存目录：\(batchDirectory)")) }
            progress(L10n.text("回读校验 \(index + 1)/\(jobs.count)：\(job.name)"), (Double(index) + 0.8) / Double(jobs.count))
            fileCount += try verify(source: job.source.path, destination: job.destination.path, local: local, target: target, cancellation: cancellation, depth: 0)
        }
        try cancellation.check()
        progress(L10n.text("目标机器回读校验通过"), 1)
        return UploadedAttachments(directory: batchDirectory, paths: jobs.map { $0.destination.path }, fileCount: fileCount)
    }
    private func verify(source: String, destination: String, local: LocalFileClient, target: any FileClient,
                        cancellation: CancellationFlag, depth: Int) throws -> Int {
        try cancellation.check()
        guard depth < 128 else { throw WorkbenchError.message(L10n.text("附件目录层级过深")) }
        let sourceAttributes = try local.stat(source); let destinationAttributes = try target.stat(destination)
        guard !sourceAttributes.isSymbolicLink, !destinationAttributes.isSymbolicLink else { throw WorkbenchError.message(L10n.text("附件不允许符号链接")) }
        if sourceAttributes.isDirectory {
            guard destinationAttributes.isDirectory else { throw WorkbenchError.message(L10n.text("附件目录校验失败")) }
            try target.chmod(destination, permissions: 0o700)
            let children = try local.list(source)
            guard Set(children.map(\.name)) == Set(try target.list(destination).map(\.name)) else { throw WorkbenchError.message(L10n.text("附件目录在上传期间发生变化")) }
            var count = 0
            for child in children { count += try verify(source: child.path, destination: RemotePath.join(destination, child.name), local: local, target: target, cancellation: cancellation, depth: depth + 1) }
            return count
        }
        guard sourceAttributes.isRegularFile, destinationAttributes.isRegularFile, sourceAttributes.size == destinationAttributes.size else {
            throw WorkbenchError.message(L10n.text("目标机器附件大小或类型校验失败，未插入路径。"))
        }
        try target.chmod(destination, permissions: 0o600)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: source)); defer { try? handle.close() }
        var sourceHash = SHA256(); var targetHash = SHA256(); var offset: UInt64 = 0
        while offset < sourceAttributes.size {
            try cancellation.check()
            let length = Int(min(UInt64(2 * 1024 * 1024), sourceAttributes.size - offset))
            let sourceData = try handle.read(upToCount: length) ?? Data()
            let targetData = try target.preview(destination, offset: offset, limit: length)
            guard sourceData.count == length, targetData.count == length else { throw WorkbenchError.message(L10n.text("附件回读长度不一致")) }
            sourceHash.update(data: sourceData); targetHash.update(data: targetData); offset += UInt64(length)
        }
        if sourceAttributes.size == 0 { _ = try target.preview(destination, offset: 0, limit: 1) }
        let sourceAfter = try local.stat(source); let targetAfter = try target.stat(destination)
        guard sourceHash.finalize() == targetHash.finalize(), sourceAfter.size == sourceAttributes.size, sourceAfter.modified == sourceAttributes.modified,
              targetAfter.size == destinationAttributes.size, targetAfter.modified == destinationAttributes.modified else {
            throw WorkbenchError.message(L10n.text("附件内容校验失败，未插入路径。"))
        }
        return 1
    }
}
