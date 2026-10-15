import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkPreviewServer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farport-web-tests-" + UUID().uuidString)
    let folder = root.appendingPathComponent("report")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let html = Data("<html><link rel='stylesheet' href='style.css'><h1 id='c322'>报告</h1></html>".utf8)
    try html.write(to: folder.appendingPathComponent("index.html"))
    try Data("h1 { color: teal }".utf8).write(to: folder.appendingPathComponent("style.css"))
    try Data("not exposed".utf8).write(to: root.appendingPathComponent("private.txt"))
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.txt"), withDestinationURL: root.appendingPathComponent("private.txt"))
    let transport = SSHTransport(paths: try ApplicationPaths(root: root.appendingPathComponent("config")))
    let server = try FilePreviewServer(transport: transport, host: nil, directory: folder.path)
    defer { server.stop() }
    let url = try server.url(for: "index.html")
    try expect(url.host == "127.0.0.1" && url.pathComponents[1].count == 64, "仅回环地址和随机 256 bit 令牌")
    func request(_ target: String, extra: [String] = []) throws -> (String, Data, String) {
        let header = root.appendingPathComponent("headers"); let body = root.appendingPathComponent("body")
        let result = try ProcessRunner.run(executable: "/usr/bin/curl", arguments: ["--noproxy", "*", "--path-as-is", "--max-time", "8", "-sS", "-D", header.path, "-o", body.path, "-w", "%{http_code}"] + extra + [target], timeout: 10)
        guard result.status == 0 else { throw WorkbenchError.message("预览 HTTP 请求失败") }
        return (result.text, (try? Data(contentsOf: body)) ?? Data(), try String(contentsOf: header, encoding: .utf8))
    }
    let document = try request(url.absoluteString + "?view=1#c322")
    try expect(document.0 == "200" && document.1 == html, "真实 HTTP HTML 查询与锚点访问：status=\(document.0)，bytes=\(document.1.count)，root=\(server.root)")
    try expect(document.2.contains("script-src 'none'") && document.2.contains("Cache-Control: no-store") && !document.2.contains("Access-Control-Allow-Origin"), "默认禁用脚本、缓存和跨域访问")
    let base = url.deletingLastPathComponent().absoluteString
    let css = try request(base + "style.css")
    try expect(css.0 == "200" && css.2.contains("text/css"), "相对 CSS 按需读取")
    let range = try request(url.absoluteString, extra: ["-H", "Range: bytes=1-4"])
    try expect(range.0 == "206" && range.1 == html.subdata(in: 1..<5), "字节范围读取正确")
    let suffix = try request(url.absoluteString, extra: ["-H", "Range: bytes=-3"])
    try expect(suffix.0 == "206" && suffix.1 == html.suffix(3), "后缀范围读取")
    try expect(try request(url.absoluteString, extra: ["-H", "Range: bytes=90000-"]).0 == "416", "非法范围拒绝")
    try expect(try request(url.absoluteString, extra: ["-I"]).0 == "200", "支持 HEAD")
    try expect(try request(url.absoluteString, extra: ["-X", "POST"]).0 == "405", "不允许远程写操作")
    try expect(try request(url.absoluteString, extra: ["-H", "Host: evil.invalid"]).0 == "403", "Host 校验防 DNS rebinding")
    try expect(try request(url.absoluteString, extra: ["-H", "Origin: https://evil.invalid"]).0 == "403", "不允许外站 Origin")
    try expect(try request(base + "../private.txt").0 == "403", "拒绝目录穿越")
    try expect(try request(base + "%2e%2e/private.txt").0 == "403", "拒绝编码目录穿越")
    try expect(try request(base + "linked.txt").0 == "403", "拒绝符号链接越界")
    try expect(try request("http://127.0.0.1:\(server.port)/wrong/index.html").0 == "404", "错误令牌不可读取")
    let trusted = try FilePreviewServer(transport: transport, host: nil, directory: folder.path, allowsScripts: true)
    defer { trusted.stop() }
    let trustedResponse = try request(trusted.url(for: "index.html").absoluteString)
    try expect(trustedResponse.2.contains("script-src 'self' 'unsafe-inline'") && trustedResponse.2.contains("connect-src 'self'"), "信任模式只允许目录内脚本和数据")
    server.stop(); try expect(!server.isRunning, "预览服务可撤销")
    try rejects("服务撤销后不得生成链接") { _ = try server.url(for: "index.html") }
    let media = try FilePreviewServer(transport: transport, host: nil, directory: folder.path, fileName: "style.css")
    defer { media.stop() }
    let mediaURL = try media.url(for: "style.css")
    try expect(try request(mediaURL.absoluteString, extra: ["-H", "Range: bytes=0-3"]).0 == "206", "单文件媒体模式支持 Range")
    try expect(try request(mediaURL.deletingLastPathComponent().appendingPathComponent("index.html").absoluteString).0 == "403", "媒体预览不得访问同目录其他文件")
    let large = folder.appendingPathComponent("large.mp4")
    FileManager.default.createFile(atPath: large.path, contents: nil)
    let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: 300 * 1024 * 1024); try handle.close()
    let largeServer = try FilePreviewServer(transport: transport, host: nil, directory: folder.path, fileName: "large.mp4")
    defer { largeServer.stop() }
    try expect(try request(largeServer.url(for: "large.mp4").absoluteString, extra: ["-I"]).0 == "200", "媒体模式大于256MiB文件不需完整下载")
}
