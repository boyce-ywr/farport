import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkReleaseUpdates() throws {
    let digest = "sha256:" + String(repeating: "a", count: 64)
    func asset(_ name: String, hash: String? = nil, size: Int = 100) -> [String: Any] {
        ["id": 10, "name": name, "size": size, "digest": hash ?? digest]
    }
    func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, assets: [[String: Any]] = []) throws -> GitHubRelease {
        let json: [String: Any] = ["id": 1, "tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": assets]
        return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: json))
    }
    try expect(ReleaseVersion("0.1.10")! > ReleaseVersion("v0.1.9")!, "版本按数字而非字符串比较")
    for invalid in ["1.2", "01.2.3", "1.2.3-beta", "1.2.3+build", "1.2.3 ", "1.2.-3", "１.2.3", "1..3", "../../tmp"] {
        try expect(ReleaseVersion(invalid) == nil, "拒绝非法正式版本：\(invalid)")
    }
    let older = try release("v0.1.3")
    let newer = try release("v0.1.10", assets: [asset("Farport-0.1.10-arm64.dmg"), asset("Farport-0.1.10-universal.dmg")])
    let releases = [older, newer, try release("v9.0.0", draft: true), try release("v10.0.0", prerelease: true)]
    let selected = try ReleaseUpdate.select(from: releases, current: "0.1.4", architecture: "arm64")
    try expect(selected?.version == ReleaseVersion("0.1.10"), "忽略草稿及预发行版本")
    try expect(selected?.asset?.name == "Farport-0.1.10-arm64.dmg", "优先匹配芯片的独立安装包")
    try expect(try ReleaseUpdate.select(from: releases, current: "0.1.10", architecture: "arm64") == nil, "相同版本不更新")
    try expect(try ReleaseUpdate.select(from: [older], current: "0.1.4", architecture: "arm64") == nil, "不降级")
    try expect(try ReleaseUpdate.select(from: [], current: "0.1.4", architecture: "arm64") == nil, "无 Release 正常返回")
    try rejects("非法当前版本") { _ = try ReleaseUpdate.select(from: releases, current: "unknown", architecture: "arm64") }
    for architecture in ["arm64", "x86_64"] {
        let only = try release("v0.1.10", assets: [asset("Farport-0.1.10-\(architecture).dmg")])
        try expect(try ReleaseUpdate.select(from: [only], current: "0.1.4", architecture: architecture)?.asset != nil, "选择匹配架构：\(architecture)")
        let other = architecture == "arm64" ? "x86_64" : "arm64"
        try expect(try ReleaseUpdate.select(from: [only], current: "0.1.4", architecture: other)?.asset == nil, "拒绝错误架构安装包")
    }
    for bad in [asset("../../Farport-0.1.10-universal.dmg"), asset("Farport-0.1.10-universal.dmg", hash: "sha256:bad"), asset("Farport-0.1.10-universal.dmg", size: 0), asset("Farport-0.1.10-universal.dmg", size: 2_000_000_000)] {
        let invalid = try release("v0.1.10", assets: [bad])
        try expect(try ReleaseUpdate.select(from: [invalid], current: "0.1.4", architecture: "arm64")?.asset == nil, "拒绝不可信的附件元数据")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("farport-update-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("fixture.dmg")
    try Data("abc".utf8).write(to: file)
    let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    try GitHubUpdateService.verify(file: file, size: 3, sha256: hash)
    try expect(true, "流式 SHA-256 校验成功")
    try rejects("错误大小") { try GitHubUpdateService.verify(file: file, size: 4, sha256: hash) }
    try rejects("错误摘要") { try GitHubUpdateService.verify(file: file, size: 3, sha256: String(repeating: "0", count: 64)) }
    let cancelled = CancellationFlag(); cancelled.cancel()
    try rejects("校验可取消") { try GitHubUpdateService.verify(file: file, size: 3, sha256: hash, cancellation: cancelled) }
    try rejects("取消下载不创建残留") { _ = try GitHubUpdateService.download(selected!, into: directory, cancellation: cancelled) { _ in } }
    try expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["fixture.dmg"], "取消后无下载残留")
    for message in ["HTTP 401 secret-value", "HTTP 403 secret-value", "HTTP 404 secret-value", "network secret-value"] {
        try expect(!GitHubUpdateService.failure(message).localizedDescription.contains("secret-value"), "错误提示不暴露原始响应")
    }
}

func checkLiveRelease() throws {
    let releases = try GitHubUpdateService.releases()
    if let update = try ReleaseUpdate.select(from: releases, current: "0.1.3", architecture: "arm64"), update.asset != nil {
        let root = URL(fileURLWithPath: ".test/update-download").standardizedFileURL
        let file = try GitHubUpdateService.download(update, into: root, cancellation: CancellationFlag()) { _ in }
        print("PASS · 私有 Release \(update.version.description) 下载、SHA-256 与 DMG 校验：\(file.lastPathComponent)")
    } else { print("PASS · 已授权访问私有 Release API；尚无可供升级的安装包") }
}
