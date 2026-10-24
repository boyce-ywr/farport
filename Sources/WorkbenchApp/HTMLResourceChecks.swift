import AppKit
import WebKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum HTMLResourceChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let store = workspace.store
        let host: HostProfile?
        if ProcessInfo.processInfo.environment["SWB_QA_REQUIRE_SSH"] == "1" {
            guard let fixture = store.hosts.first(where: { $0.address == "127.0.0.1" && $0.port == 22281 }) else { throw WorkbenchError.message("HTML 资源检查仅允许隔离 SSH 主机") }
            host = fixture
        } else { host = nil }
        let directory = host == nil ? store.paths.root.appendingPathComponent("html-resources").path : "/tmp/farport-html-resources-" + UUID().uuidString
        let transport = store.transport
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for row in 0..<64 {
            for column in 0..<96 { bitmap.setColor(NSColor(calibratedRed: Double(column) / 120, green: 0.55, blue: 0.3 + Double(row) / 110, alpha: 1), atX: column, y: row) }
        }
        let image = bitmap.representation(using: .png, properties: [:])!
        let paths = ["cover image 中文.png"] + (1...11).map { "assets/gallery/tile \($0).png" }
        let cards = paths.enumerated().map { index, path in
            "<figure><img id='image-\(index)' src='./\(path)?v=1' width='96' height='64'><figcaption>\(index == 0 ? "同级目录 · 中文与空格" : "子目录 · 图片 \(index)")</figcaption></figure>"
        }.joined()
        let html = Data("""
        <!doctype html><html><head><meta charset="utf-8"><title>Farport · HTML Resources</title><link rel="stylesheet" href="styles/report.css"></head>
        <body><header>FARPORT / HTML PREVIEW</header><h1>不止 HTML，资源一起呈现。</h1><p>同级图片 · 子目录图片 · 嵌套样式 · SVG</p>
        <main>\(cards)<figure><img id="vector" src="assets/mark.svg" width="96" height="64"><figcaption>子目录 · SVG</figcaption></figure></main>
        <footer id="background">CSS 相对图片引用</footer><p id="script-state">安全模式：脚本默认不执行</p>
        <script src="scripts/report.js"></script><script type="module" src="scripts/report.mjs"></script></body></html>
        """.utf8)
        let css = Data("""
        @import url('./palette.css');
        body{font:14px -apple-system,sans-serif;background:#f3f8f9;color:#19363c;padding:24px;margin:0}header{color:#25868b;font-size:11px;letter-spacing:2px}h1{font-size:23px;margin:18px 0 8px}p{color:#537478}main{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}figure{margin:0;border-radius:10px;background:white;padding:10px;box-shadow:0 2px 8px #143a4210}img{display:block;width:100%;height:64px;object-fit:cover;border-radius:5px}figcaption{font-size:10px;color:#537478;margin-top:8px}footer{margin-top:18px;background-image:url('../cover image 中文.png');padding:12px;border-radius:8px;color:white}#script-state{font-size:11px}
        """.utf8)
        var resources = paths.map { ($0, image) }
        resources += [
            ("index.html", html), ("styles/report.css", css), ("styles/palette.css", Data("body{--resource-palette:ready}".utf8)),
            ("assets/mark.svg", Data("<svg xmlns='http://www.w3.org/2000/svg' width='96' height='64'><rect width='96' height='64' fill='#123f46'/><circle cx='48' cy='32' r='19' fill='#31c7ba'/></svg>".utf8)),
            ("scripts/report.js", Data("document.body.dataset.classic='ready';document.getElementById('script-state').textContent='信任模式：本地脚本已加载';".utf8)),
            ("scripts/report.mjs", Data("import { value } from './helper.mjs';fetch('./data/summary.json').then(r=>r.json()).then(data=>{document.body.dataset.module=value+data.status});".utf8)),
            ("scripts/helper.mjs", Data("export const value='module-';".utf8)),
            ("data/summary.json", Data("{\"status\":\"ready\"}".utf8))
        ]
        let files = resources
        try await Task.detached {
            let client = try transport.files(host); defer { client.close() }
            try client.mkdir(directory)
            for child in ["assets", "assets/gallery", "styles", "scripts", "data"] { try client.mkdir(directory + "/" + child) }
            for (name, data) in files {
                let path = directory + "/" + name
                try client.createFile(path); try client.saveText(path, data: data, expected: client.stat(path), original: Data())
            }
        }.value
        workspace.browseFiles(host.map { .host($0.id) } ?? .local)
        guard let model = workspace.currentFileBrowser else { throw WorkbenchError.message("没有 HTML 文件浏览模型") }
        defer {
            model.closeSpotlight(); model.stopWebPreview(); model.stop()
            let client = try? transport.files(host); try? client?.removeRecursively(directory); client?.close()
        }
        try await wait { !model.busy }
        model.load(directory)
        try await wait { !model.busy && model.path == directory }
        guard let file = model.files.first(where: { $0.name == "index.html" }) else { throw WorkbenchError.message("缺少 HTML 样例") }
        model.previewRatio = 0.65; model.showPreview = true; model.selection = [file.path]; model.preview(file)
        for scene in ["sidebar", "spotlight", "trusted"] {
            if scene == "spotlight" { model.activate(file) }
            if scene == "trusted" { model.startWebPreview(allowScripts: true) }
            try await wait { !model.previewBusy && model.webURL != nil }
            guard let url = model.webURL else { throw WorkbenchError.message("HTML 资源服务未启动") }
            try await wait { webViews().contains { $0.url == url && !$0.isLoading } }
            guard let webView = webViews().last(where: { $0.url == url }) else { throw WorkbenchError.message("未找到真实 WKWebView") }
            try await inspect(webView, trusted: scene == "trusted")
            if scene == "spotlight", let content = webView.window?.contentView,
               let snapshot = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: snapshot)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try snapshot.representation(using: .png, properties: [:])?.write(to: output)
            }
            print("PASS · \(host == nil ? "本机" : "SSH") \(scene)：13张关联图片真实解码、嵌套CSS、SVG、脚本权限与模块数据引用")
        }
    }
    private static func inspect(_ view: WKWebView, trusted: Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        var last = ""
        repeat {
            let result = try await view.evaluateJavaScript("""
            JSON.stringify({images:[...document.images].map(image=>({name:image.id,loaded:image.complete&&image.naturalWidth>0})),palette:getComputedStyle(document.body).getPropertyValue('--resource-palette').trim(),classic:document.body.dataset.classic||'',module:document.body.dataset.module||''})
            """, in: nil, contentWorld: .defaultClient)
            last = result as? String ?? ""
            if let data = last.data(using: .utf8), let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let images = state["images"] as? [[String: Any]], images.count == 13, images.allSatisfy({ $0["loaded"] as? Bool == true }),
               state["palette"] as? String == "ready" {
                if trusted {
                    if state["classic"] as? String == "ready", state["module"] as? String == "module-ready" { return }
                } else {
                    guard state["classic"] as? String == "", state["module"] as? String == "" else { throw WorkbenchError.message("未信任的 HTML 脚本被执行") }
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw WorkbenchError.message("HTML 关联资源未完整渲染：" + last)
    }
    private static func webViews() -> [WKWebView] {
        func find(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(find) }
        return NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(find)
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() {
            guard Date() < deadline else { throw WorkbenchError.message("HTML 资源界面检查超时") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
