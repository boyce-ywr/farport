import Foundation
import CryptoKit
import Darwin
import WorkbenchCore

public enum GitHubUpdateService {
    public static let repository = "boyce-ywr/farport"
    public static func executable() throws -> String {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/gh" }
        guard let executable = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw WorkbenchError.message(L10n.text("应用内更新需要 GitHub CLI。请先安装 gh，并在终端运行 gh auth login --hostname github.com --git-protocol https --web。"))
        }
        return executable
    }
    private static var environment: [String: String] {
        var result = ProcessInfo.processInfo.environment
        if result["HTTPS_PROXY"] == nil, result["https_proxy"] == nil,
           (try? ProcessRunner.run(executable: "/usr/bin/nc", arguments: ["-z", "-w", "1", "127.0.0.1", "7897"], timeout: 2).status) == 0 {
            result["HTTPS_PROXY"] = "http://127.0.0.1:7897"
            result["HTTP_PROXY"] = "http://127.0.0.1:7897"
        }
        result["GH_HOST"] = "github.com"
        result["GH_PROMPT_DISABLED"] = "1"
        result["GH_PAGER"] = "cat"
        result.removeValue(forKey: "GH_DEBUG")
        return result
    }
    public static func releases(cancellation: CancellationFlag = CancellationFlag()) throws -> [GitHubRelease] {
        let result = try ProcessRunner.run(executable: executable(), arguments: ["api", "--hostname", "github.com", "--paginate", "--slurp", "repos/\(repository)/releases?per_page=100"], environment: environment, cancellation: cancellation, timeout: 35)
        guard result.status == 0 else { throw failure(result.error) }
        do { return try JSONDecoder().decode([[GitHubRelease]].self, from: result.output).flatMap { $0 } }
        catch { throw WorkbenchError.message(L10n.text("GitHub Release 返回格式不正确，请稍后重试。")) }
    }
    public static func failure(_ message: String) -> Error {
        let value = message.lowercased()
        if value.contains("auth login") || value.contains("http 401") || value.contains("not logged") || value.contains("bad credentials") {
            return WorkbenchError.message(L10n.text("GitHub CLI 尚未登录或授权已失效。请在终端运行 gh auth login --hostname github.com --git-protocol https --web 后重试。"))
        }
        if value.contains("http 404") { return WorkbenchError.message(L10n.text("无法读取 boyce-ywr/farport 仓库。请检查网络、仓库状态及 gh 登录权限。")) }
        if value.contains("http 403") || value.contains("rate limit") { return WorkbenchError.message(L10n.text("GitHub 拒绝了请求，可能是权限不足或访问频率限制，请稍后重试。")) }
        return WorkbenchError.message(L10n.text("无法连接 GitHub，请检查网络或代理后重试。未下载或安装更新。"))
    }
    public static func download(_ update: ReleaseUpdate, into root: URL, cancellation: CancellationFlag,
                                progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        guard let asset = update.asset, let expectedHash = asset.sha256,
              asset.id > 0, asset.size > 0, asset.size <= 1024 * 1024 * 1024,
              asset.name == "Farport-\(update.version.description)-universal.dmg" || asset.name == "Farport-\(update.version.description)-arm64.dmg" || asset.name == "Farport-\(update.version.description)-x86_64.dmg" else {
            throw WorkbenchError.message(L10n.text("Release 没有可校验的匹配安装包，未开始下载。"))
        }
        try cancellation.check()
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        let partial = directory.appendingPathComponent("download.part")
        let destination = directory.appendingPathComponent(asset.name)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw WorkbenchError.message(L10n.text("无法创建更新下载文件。")) }
        let file = try FileHandle(forWritingTo: partial)
        let process = Process(); let error = Pipe(); let errors = CapturedOutput(); let readers = DispatchGroup()
        process.executableURL = URL(fileURLWithPath: try executable())
        process.arguments = ["api", "--hostname", "github.com", "repos/\(repository)/releases/assets/\(asset.id)", "--header", "Accept: application/octet-stream"]
        process.environment = environment; process.standardInput = FileHandle.nullDevice; process.standardOutput = file; process.standardError = error
        defer {
            if process.isRunning { process.terminate(); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
            try? file.close()
        }
        try process.run()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readers.leave() }
            while let bytes = try? error.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty { errors.append(bytes, limit: 65536) }
        }
        var previousSize: UInt64 = 0; var changed = Date(); let deadline = Date().addingTimeInterval(1200)
        while process.isRunning {
            try cancellation.check()
            let size = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.uint64Value ?? 0
            guard size <= UInt64(asset.size) else { throw WorkbenchError.message(L10n.text("下载内容超过声明大小，已中止。")) }
            if size != previousSize { previousSize = size; changed = Date(); progress(min(0.95, Double(size) / Double(asset.size) * 0.95)) }
            guard Date().timeIntervalSince(changed) < 60, Date() < deadline else { throw WorkbenchError.message(L10n.text("更新下载长时间没有进展，已中止；可以重新下载。")) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit(); _ = readers.wait(timeout: .now() + 3)
        try file.synchronize(); try file.close(); try cancellation.check()
        guard process.terminationStatus == 0 else { throw failure(String(decoding: errors.data, as: UTF8.self)) }
        try verify(file: partial, size: asset.size, sha256: expectedHash, cancellation: cancellation)
        let image = try ProcessRunner.run(executable: "/usr/bin/hdiutil", arguments: ["verify", partial.path], cancellation: cancellation, timeout: 90)
        guard image.status == 0 else { throw WorkbenchError.message(L10n.text("下载的磁盘映像校验失败，未打开安装包。")) }
        try FileManager.default.moveItem(at: partial, to: destination)
        success = true; progress(1)
        return destination
    }
    public static func verify(file: URL, size: Int64, sha256: String, cancellation: CancellationFlag = CancellationFlag()) throws {
        try cancellation.check()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.int64Value == size else { throw WorkbenchError.message(L10n.text("更新文件类型或大小不一致，未打开。")) }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { try cancellation.check(); hash.update(data: bytes) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == sha256.lowercased() else { throw WorkbenchError.message(L10n.text("更新文件 SHA-256 不匹配，未打开。请重新下载。")) }
    }
}
