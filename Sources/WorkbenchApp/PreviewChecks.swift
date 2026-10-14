import AppKit
import Foundation
import PDFKit
import WebKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum PreviewChecks {
    static func run(workspace: Workspace, pdf: Bool, output: URL) async throws {
        let host = workspace.store.hosts.first
        guard let host, host.address == "127.0.0.1", [22281, 22282].contains(host.port) else { throw WorkbenchError.message("仅允许隔离 SSH 测试主机") }
        let directory = "/tmp/farport-preview-" + UUID().uuidString
        let html = Data("""
        <!doctype html><html><head><meta charset="utf-8"><title>Farport Remote Report</title><link rel="stylesheet" href="style.css"></head>
        <body><header>FARPORT / REMOTE REPORT</header><h1 id="c322">远端报告，即刻预览。</h1><p>通过 SSH 安全读取，CSS 与图片按需加载。</p>
        <section><strong>100%</strong><span>回环地址 · 目录隔离 · 相对资源</span></section><a href="#details">跳到详细结果 ↓</a>
        <p id="script-state">安全模式：脚本未执行</p><div style="height:140px"></div><h2 id="details">验证结果</h2><p>浏览器直接打开同一个临时链接，无需部署远端 Web 服务。</p>
        <script>document.getElementById('script-state').textContent='可信模式：脚本已执行';</script></body></html>
        """.utf8)
        let css = Data("body{font:16px -apple-system,sans-serif;background:#f3f8f9;color:#19363c;margin:0;padding:42px}header{font-size:12px;letter-spacing:2px;color:#25868b}h1{font-size:30px;margin-top:38px}section{background:#123f46;border-radius:14px;padding:25px;color:white;display:flex;flex-direction:column;gap:12px;margin:25px 0}strong{font-size:42px}a{color:#187f8c}p{line-height:1.8}".utf8)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        text.string = "Farport PDF Preview\n\n远端 PDF 文档预览\n\n原生 PDFKit · 翻页 · 缩放\n\n无需将文件手动下载到磁盘。"
        text.font = NSFont.systemFont(ofSize: 22); text.textColor = .black; text.backgroundColor = .white
        let document = text.dataWithPDF(inside: text.bounds)
        let transport = workspace.store.transport
        try await Task.detached {
            let client = try transport.files(host); defer { client.close() }
            try client.mkdir(directory)
            for (name, data) in [("index.html", html), ("style.css", css), ("guide.pdf", document)] {
                let target = directory + "/" + name
                try client.createFile(target); try client.saveText(target, data: data, expected: client.stat(target), original: Data())
            }
        }.value
        workspace.browseFiles(.host(host.id))
        guard let model = workspace.currentFileBrowser else { throw WorkbenchError.message("文件模型不可用") }
        try await wait { !model.busy }
        model.load(directory)
        try await wait { !model.busy && model.path == directory }
        let filename = pdf ? "guide.pdf" : "index.html"
        guard let file = model.files.first(where: { $0.name == filename }) else { throw WorkbenchError.message("缺少预览测试文件") }
        model.selection = [file.path]; model.preview(file)
        try await wait { !model.previewBusy }
        if !pdf, ProcessInfo.processInfo.environment["SWB_QA_TRUST_HTML"] == "1" {
            model.startWebPreview(allowScripts: true)
            try await wait { !model.previewBusy }
        }
        model.previewRatio = 0.56
        if pdf {
            guard model.previewPDF?.pageCount == 1 else { throw WorkbenchError.message("远端 PDF 未完整解析") }
            print("PASS · 远端 PDF 完整读取与原生 PDFKit 一页文档预览")
        } else {
            guard let url = model.webURL else { throw WorkbenchError.message(model.errorMessage ?? "HTML 代理未启动") }
            let response = try await Task.detached { try ProcessRunner.run(executable: "/usr/bin/curl", arguments: ["--noproxy", "*", "--max-time", "15", "-fsS", url.absoluteString], timeout: 18) }.value
            guard response.status == 0, response.output == html else { throw WorkbenchError.message("HTTP 未返回真实远端 HTML") }
            let styleURL = url.deletingLastPathComponent().appendingPathComponent("style.css")
            let style = try await Task.detached { try ProcessRunner.run(executable: "/usr/bin/curl", arguments: ["--noproxy", "*", "--max-time", "15", "-fsS", styleURL.absoluteString], timeout: 18) }.value
            guard style.output == css else { throw WorkbenchError.message("相对 CSS 资源读取失败") }
            try JSONSerialization.data(withJSONObject: ["url": url.absoluteString, "directory": directory]).write(to: output.deletingLastPathComponent().appendingPathComponent("browser-preview.json"))
            print("PASS · 远端 HTML 与相对 CSS 通过真实回环 HTTP / SFTP 读取；测试链接只保存在忽略目录")
        }
        try await Task.sleep(for: .milliseconds(800))
        if !pdf {
            func findWeb(_ view: NSView) -> WKWebView? {
                if let web = view as? WKWebView { return web }
                for child in view.subviews { if let web = findWeb(child) { return web } }
                return nil
            }
            guard let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView, let web = findWeb(content) else { throw WorkbenchError.message("没有挂载网页预览视图") }
            try await wait { !web.isLoading && web.title == "Farport Remote Report" }
            print("PASS · WKWebView 已加载远端报告标题")
        }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() { guard Date() < end else { throw WorkbenchError.message("预览验收超时") }; try await Task.sleep(for: .milliseconds(100)) }
    }
}
