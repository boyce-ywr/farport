import AppKit
import Foundation
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum FileBrowsingChecks {
    static let markdown = """
    # Farport 工作笔记

    **重点**：安全连接，专注工作。支持 *强调* 与 ~~删除线~~。

    ## 待办事项

    - 打开符号链接目录
    - 预览并编辑 Markdown

    > 文件保存在目标主机，预览不会执行脚本。

    ```swift
    let connection = "SSH"
    ```

    | 功能 | 状态 |
    | --- | --- |
    | 预览 | 正常 |
    | 编辑 | 可用 |
    """

    static func run(workspace: Workspace) async throws {
        try await check(host: nil, workspace: workspace)
        if let host = workspace.store.hosts.first, host.address == "127.0.0.1", [22281, 22282].contains(host.port) { try await check(host: host, workspace: workspace) }
        let rendered = MarkdownRendering.render(markdown)
        guard rendered.string.contains("Farport 工作笔记"), !rendered.string.contains("**重点**"), rendered.string.contains("• "), rendered.string.contains("\t") else { throw WorkbenchError.message("Markdown 块级格式未正确呈现") }
        let unsafe = MarkdownRendering.render("[unsafe](javascript:alert(1))\n\n<script>alert(1)</script>")
        var unsafeLink = false
        unsafe.enumerateAttribute(.link, in: NSRange(location: 0, length: unsafe.length)) { value, _, _ in if value != nil { unsafeLink = true } }
        guard !unsafeLink else { throw WorkbenchError.message("Markdown 放行了不安全链接") }
        print("PASS · 本机/隔离SSH 目录链接单击预览和打开、普通文件链接只读、失效链接、Markdown 原生渲染与冲突保护保存")
    }

    private static func check(host: HostProfile?, workspace: Workspace) async throws {
        let transport = workspace.store.transport
        let directory = host == nil ? workspace.store.paths.root.appendingPathComponent("browse-fixture-" + UUID().uuidString).path : "/tmp/farport-browse-" + UUID().uuidString
        let text = Data(markdown.utf8)
        try await Task.detached {
            let client = try transport.files(host); defer { client.close() }
            if host == nil { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
            else { try client.mkdir(directory) }
            try client.mkdir(directory + "/documents")
            let file = directory + "/documents/README.md"
            try client.createFile(file); try client.saveText(file, data: text, expected: client.stat(file), original: Data())
            if let host {
                _ = try transport.run(host, command: "ln -s documents \(RemotePath.quote(directory + "/shared")); ln -s documents/README.md \(RemotePath.quote(directory + "/note.md")); ln -s missing \(RemotePath.quote(directory + "/broken"))").checked()
            } else {
                try FileManager.default.createSymbolicLink(atPath: directory + "/shared", withDestinationPath: "documents")
                try FileManager.default.createSymbolicLink(atPath: directory + "/note.md", withDestinationPath: "documents/README.md")
                try FileManager.default.createSymbolicLink(atPath: directory + "/broken", withDestinationPath: "missing")
            }
        }.value
        workspace.browseFiles(host.map { .host($0.id) } ?? .local)
        guard let model = workspace.currentFileBrowser else { throw WorkbenchError.message("没有文件浏览模型") }
        try await wait { !model.busy }; model.load(directory)
        try await wait { !model.busy && model.path == directory }
        guard let folderLink = model.files.first(where: { $0.name == "shared" }), let fileLink = model.files.first(where: { $0.name == "note.md" }), let broken = model.files.first(where: { $0.name == "broken" }) else { throw WorkbenchError.message("链接测试文件缺失") }
        model.selection = [folderLink.path]; model.preview(folderLink)
        try await wait { !model.previewBusy }
        guard model.previewTargetIsDirectory, model.errorMessage == nil, model.previewFile?.attributes.isSymbolicLink == true else { throw WorkbenchError.message("目录链接被误当成特殊设备") }
        model.activate(folderLink)
        try await wait { !model.busy && model.path.hasSuffix("/documents") }
        guard model.files.contains(where: { $0.name == "README.md" }) else { throw WorkbenchError.message("链接打开后未列出目标文件") }
        model.load(directory); try await wait { !model.busy }
        model.selection = [fileLink.path]; model.preview(fileLink); try await wait { !model.previewBusy }
        guard model.previewData == text, !model.editable else { throw WorkbenchError.message("普通文件链接未能预览或错误启用编辑") }
        model.selection = [broken.path]; model.preview(broken); try await wait { !model.previewBusy }
        guard model.errorMessage?.contains("符号链接") == true else { throw WorkbenchError.message("失效链接提示不清晰") }
        model.errorMessage = nil; model.load(directory + "/documents"); try await wait { !model.busy }
        guard let file = model.files.first(where: { $0.name == "README.md" }) else { throw WorkbenchError.message("Markdown 文件缺失") }
        model.selection = [file.path]; model.preview(file); try await wait { !model.previewBusy }
        guard model.isMarkdown, model.editable, model.previewData == text else { throw WorkbenchError.message("Markdown 预览/编辑入口未启用") }
        let original = model.previewFile!.attributes
        let edited = Data((markdown + "\n\n保存验证通过。\n").utf8)
        try await Task.detached {
            let client = try transport.files(host); defer { client.close() }
            try client.saveText(file.path, data: edited, expected: original, original: text)
            guard try client.preview(file.path) == edited else { throw WorkbenchError.message("Markdown 保存后回读不一致") }
            do { try client.saveText(file.path, data: text, expected: original, original: text) }
            catch { return }
            throw WorkbenchError.message("旧版本 Markdown 保存未拒绝冲突")
        }.value
        model.load(); try await wait { !model.busy }
        if let updated = model.files.first(where: { $0.path == file.path }) { model.preview(updated); try await wait { !model.previewBusy } }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("文件浏览验证超时") }; try await Task.sleep(for: .milliseconds(80)) }
    }
}
