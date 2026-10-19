import Foundation
import AppKit
import SwiftUI
import WorkbenchCore
import OpenSSHBackend
import PDFKit

@MainActor
final class FileModel: ObservableObject {
    let id = UUID()
    @Published var path = "."
    @Published var pathInput = "."
    @Published var files: [RemoteFile] = [] { didSet { visibleFilesCache = nil } }
    @Published var selection: Set<String> = []
    @Published var busy = false
    @Published private(set) var loadingPath: String?
    @Published private(set) var loadedEntryCount = 0
    @Published var previewBusy = false
    @Published var errorMessage: String?
    @Published var skippedFileNames = 0
    @Published var previewFile: RemoteFile?
    @Published var previewData = Data()
    @Published var previewOffset: UInt64 = 0
    @Published var previewImage: NSImage?
    @Published var previewPDF: PDFDocument?
    @Published var previewTargetIsDirectory = false
    @Published var webURL: URL?
    @Published var webScripts = false
    @Published var previewRatio = 0.38
    @Published var fileSort = FileSort() { didSet { visibleFilesCache = nil } }
    @Published private(set) var history = DirectoryHistory()
    @Published var mediaURL: URL?
    private var mediaServer: FilePreviewServer?
    private var previewFailure: String?
    var sortOrder: [FileSortComparator] {
        get { fileSort.column.map { [FileSortComparator(column: $0, order: fileSort.descending ? .reverse : .forward)] } ?? [] }
        set {}
    }
    private var webServer: FilePreviewServer?
    private weak var store: AppStore?
    @Published var filter = "" { didSet { visibleFilesCache = nil } }
    @Published var showHidden = false { didSet { visibleFilesCache = nil } }
    private var visibleFilesCache: [RemoteFile]?
    private var visibleFilesLanguage: AppLanguage?
    @Published var followLog = false
    let host: HostProfile?
    let transport: SSHTransport
    private var navigation = CancellationFlag()
    private var previewCancellation = CancellationFlag()
    private var generation = UUID()
    private var openingLink: String?
    private var hasLoaded = false
    let previewLimit = 512 * 1024
    init(host: HostProfile?, store: AppStore) { self.host = host; transport = store.transport; self.store = store }
    var isHTML: Bool { ["html", "htm"].contains(((previewFile?.path ?? "") as NSString).pathExtension.lowercased()) }
    var isMarkdown: Bool { ["md", "markdown"].contains(((previewFile?.path ?? "") as NSString).pathExtension.lowercased()) }
    var isMedia: Bool { ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "mp4", "m4v", "mov", "webm", "mkv", "ogg", "opus"].contains(((previewFile?.path ?? "") as NSString).pathExtension.lowercased()) }
    func stopMediaPreview() { mediaServer?.stop(); mediaServer = nil; mediaURL = nil }
    func startMediaPreview() {
        guard let file = previewFile, isMedia else { return }
        let identifier = generation; let transport = transport; let host = host
        stopMediaPreview(); previewBusy = true
        Task {
            do {
                let server = try await Task.detached { try FilePreviewServer(transport: transport, host: host, directory: RemotePath.parent(file.path), fileName: file.name) }.value
                guard generation == identifier, previewFile?.path == file.path else { server.stop(); return }
                mediaServer = server; mediaURL = try server.url(for: file.name); previewBusy = false
            } catch { if generation == identifier { previewFailure = error.localizedDescription; errorMessage = previewFailure; previewBusy = false } }
        }
    }
    func stopWebPreview() { webServer?.stop(); webServer = nil; webURL = nil }
    func startWebPreview(allowScripts: Bool = false) {
        guard let file = previewFile, isHTML else { return }
        let identifier = generation; let transport = transport; let host = host
        stopWebPreview(); webScripts = allowScripts; previewBusy = true
        Task {
            do {
                let server = try await Task.detached { try FilePreviewServer(transport: transport, host: host, directory: RemotePath.parent(file.path), allowsScripts: allowScripts) }.value
                guard generation == identifier, previewFile?.path == file.path else { server.stop(); return }
                webServer = server; store?.retainPreviewServer(server)
                webURL = try server.url(for: file.name); previewBusy = false
            } catch { if generation == identifier { errorMessage = error.localizedDescription; previewBusy = false } }
        }
    }
    var visibleFiles: [RemoteFile] {
        let language = L10n.language
        if let visibleFilesCache, visibleFilesLanguage == language { return visibleFilesCache }
        let result = fileSort.sorted(files.filter { (showHidden || !$0.name.hasPrefix(".")) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) })
        visibleFilesCache = result; visibleFilesLanguage = language
        return result
    }
    var selectedFiles: [RemoteFile] { selection.isEmpty ? [] : visibleFiles.filter { selection.contains($0.path) } }
    var selectedFile: RemoteFile? { selectedFiles.count == 1 ? selectedFiles.first : nil }
    var selectedEndpoints: [FileEndpoint] { selectedFiles.map { FileEndpoint(hostID: host?.id, path: $0.path) } }
    var previewText: String { String(decoding: previewData, as: UTF8.self) }
    var binaryPreview: Bool { previewData.contains(0) && previewImage == nil }
    var editable: Bool { guard let file = previewFile else { return false }; return !previewBusy && !isMedia && !file.attributes.isDirectory && !file.attributes.isSymbolicLink && file.attributes.size <= previewLimit && previewOffset == 0 && String(data: previewData, encoding: .utf8) != nil && !binaryPreview && previewImage == nil }
    func loadIfNeeded(_ initialPath: String? = nil) {
        if !hasLoaded && !busy { load(initialPath ?? path) }
    }
    func goBack() { if let destination = history.backDestination, !busy { load(destination, returning: true) } }
    func load(_ target: String? = nil, returning: Bool = false) {
        let target = target ?? path
        guard loadingPath != target || !busy else { return }
        navigation.cancel(); navigation = CancellationFlag(); let cancellation = navigation
        previewCancellation.cancel(); generation = UUID(); previewBusy = false; previewFailure = nil; openingLink = nil
        stopMediaPreview()
        let transport = transport; let host = host
        busy = true; errorMessage = nil; loadingPath = target; loadedEntryCount = 0
        Task {
            do {
                let result = try await Task.detached { () -> (String, [RemoteFile], Int) in
                    let client = try transport.files(host, cancellation: cancellation); defer { client.close() }
                    let canonical = try client.realpath(target)
                    if let remote = client as? SFTPClient {
                        let listing = try remote.listForBrowsing(canonical) { count in
                            Task { @MainActor in
                                guard !cancellation.isCancelled, self.loadingPath == target else { return }
                                self.loadedEntryCount = max(self.loadedEntryCount, count)
                            }
                        }
                        return (canonical, listing.files, listing.skipped)
                    }
                    return (canonical, try client.list(canonical), 0)
                }.value
                guard !cancellation.isCancelled else { return }
                if returning { history.returned(to: result.0) } else { history.visited(result.0) }
                if path != result.0 { previewCancellation.cancel(); generation = UUID(); previewBusy = false; filter = ""; selection = [] }
                path = result.0; pathInput = result.0; files = result.1; skippedFileNames = result.2; busy = false; loadingPath = nil; hasLoaded = true
                selection.formIntersection(Set(files.map(\.path)))
                if selection.count != 1 { previewFile = nil; previewData = Data(); followLog = false }
            } catch { if !cancellation.isCancelled { errorMessage = error.localizedDescription; busy = false; loadingPath = nil } }
        }
    }
    func activate(_ file: RemoteFile) {
        followLog = false
        openingLink = file.attributes.isSymbolicLink ? file.path : nil
        if file.attributes.isDirectory { load(file.path) }
        else { selection = [file.path]; preview(file, openLinkedDirectory: file.attributes.isSymbolicLink) }
    }
    func preview(_ file: RemoteFile, offset: UInt64 = 0, tail: Bool = false, openLinkedDirectory: Bool = false) {
        if let previousFailure = previewFailure, errorMessage == previousFailure { errorMessage = nil }
        previewFailure = nil; stopMediaPreview()
        if openLinkedDirectory { openingLink = file.path }
        else if openingLink != file.path { openingLink = nil }
        previewCancellation.cancel(); previewCancellation = CancellationFlag(); let cancellation = previewCancellation
        let identifier = UUID(); generation = identifier
        previewFile = file; previewBusy = true
        previewData = Data(); previewImage = nil; previewPDF = nil; webURL = nil; previewTargetIsDirectory = false
        if file.attributes.isDirectory { previewData = Data(); previewImage = nil; previewBusy = false; return }
        let transport = transport; let host = host; let limit = previewLimit; let media = isMedia
        Task {
            do {
                let result = try await Task.detached { () -> (Data, FileAttributes, UInt64) in
                    let client = try transport.files(host, cancellation: cancellation); defer { client.close() }
                    let attributes = try client.stat(file.path, followLinks: true)
                    if attributes.isDirectory { return (Data(), attributes, 0) }
                    guard attributes.isRegularFile else { throw WorkbenchError.message(L10n.text("不预览设备、管道或套接字。")) }
                    if media { return (Data(), attributes, 0) }
                    let position = tail ? (attributes.size > UInt64(limit) ? attributes.size - UInt64(limit) : 0) : min(offset, attributes.size)
                    let imageType = ["png", "jpg", "jpeg", "gif", "tiff", "webp", "heic"].contains((file.path as NSString).pathExtension.lowercased())
                    if (file.path as NSString).pathExtension.lowercased() == "pdf" {
                        guard attributes.size <= 32 * 1024 * 1024 else { throw WorkbenchError.message(L10n.text("PDF 超过 32 MiB，请下载后查看。")) }
                        var data = Data()
                        while data.count < Int(attributes.size) {
                            try cancellation.check()
                            let chunk = try client.preview(file.path, offset: UInt64(data.count), limit: min(4 * 1024 * 1024, Int(attributes.size) - data.count))
                            guard !chunk.isEmpty else { throw WorkbenchError.message(L10n.text("PDF 在读取期间发生变化。")) }
                            data.append(chunk)
                        }
                        return (data, attributes, 0)
                    }
                    if imageType, attributes.size <= 8 * 1024 * 1024 {
                        return (try client.preview(file.path, offset: 0, limit: Int(attributes.size)), attributes, 0)
                    }
                    return (try client.preview(file.path, offset: position, limit: limit), attributes, position)
                }.value
                guard generation == identifier, !cancellation.isCancelled else { return }
                previewData = result.0; previewOffset = result.2
                previewTargetIsDirectory = result.1.isDirectory
                var updated = file; updated.attributes = result.1
                if file.attributes.isSymbolicLink { updated.attributes.permissions = file.attributes.permissions }
                previewFile = updated
                previewImage = NSImage(data: result.0)
                if (file.path as NSString).pathExtension.lowercased() == "pdf" {
                    previewPDF = PDFDocument(data: result.0); previewImage = nil
                    if previewPDF == nil { errorMessage = L10n.text("PDF 无法解析，可能已损坏或加密，请下载后查看。") }
                }
                previewBusy = false
                if result.1.isDirectory, openingLink == file.path { openingLink = nil; load(file.path) }
                else if media { startMediaPreview() }
                else if isHTML { startWebPreview() }
            } catch {
                if generation == identifier && !cancellation.isCancelled {
                    let failure = file.attributes.isSymbolicLink ? L10n.text("无法打开符号链接目标（可能已失效、循环或没有访问权限）：\(error.localizedDescription)") : error.localizedDescription
                    if errorMessage == nil { errorMessage = failure; previewFailure = failure }
                    previewBusy = false
                    openingLink = nil
                }
            }
        }
    }
    func deleteFiles(_ targets: [RemoteFile]) {
        guard !busy, !targets.isEmpty else { return }
        let transport = transport; let host = host
        navigation.cancel(); navigation = CancellationFlag(); let cancellation = navigation
        previewCancellation.cancel(); generation = UUID(); previewBusy = false; followLog = false
        busy = true; errorMessage = nil
        Task {
            do {
                let result = try await Task.detached { () -> (Set<String>, [String]) in
                    let client = try transport.files(host, cancellation: cancellation); defer { client.close() }
                    var deleted = Set<String>(); var failures: [String] = []
                    for file in targets {
                        try cancellation.check()
                        do { try client.removeRecursively(file.path); deleted.insert(file.path) }
                        catch { failures.append("\(file.name)：\(error.localizedDescription)") }
                    }
                    return (deleted, failures)
                }.value
                guard !cancellation.isCancelled else { return }
                files.removeAll { result.0.contains($0.path) }; selection.subtract(result.0)
                if let previewFile, result.0.contains(previewFile.path) { self.previewFile = nil; previewData = Data(); previewImage = nil }
                busy = false
                if !result.1.isEmpty { errorMessage = L10n.text("已删除 \(result.0.count) 项，\(result.1.count) 项未能完成（目录可能已部分删除）：\n") + result.1.prefix(5).joined(separator: "\n") }
            } catch { if !cancellation.isCancelled { busy = false; errorMessage = error.localizedDescription } }
        }
    }
    func perform(_ operation: @escaping @Sendable (any FileClient) throws -> Void) {
        let transport = transport; let host = host; busy = true
        Task {
            do { try await Task.detached { let client = try transport.files(host); defer { client.close() }; try operation(client) }.value; busy = false; load() }
            catch { busy = false; errorMessage = error.localizedDescription }
        }
    }
    func stop() {
        stopMediaPreview()
        if busy { hasLoaded = false }
        navigation.cancel(); previewCancellation.cancel(); generation = UUID()
        busy = false; loadingPath = nil; loadedEntryCount = 0; previewBusy = false; followLog = false
    }
}

struct EditDocument: Identifiable {
    let id = UUID()
    let file: RemoteFile
    let data: Data
}

struct RemoteEditor: View {
    let document: EditDocument
    let host: HostProfile?
    @ObservedObject var store: AppStore
    let saved: () -> Void
    @StateObject private var buffer: FileEditorBuffer
    @StateObject private var draftClipboard = TerminalClipboardState()
    @ViewState private var savedData: Data
    @ViewState private var savedAttributes: FileAttributes
    @ViewState private var busy = false
    @ViewState private var errorMessage: String?
    @ViewState private var showPreview = false
    @ViewState private var savedAt: Date?
    @ViewState private var showSaved = false
    @ViewState private var showChanges = false
    @ViewState private var draftToReview: EditorDraft?
    @ViewState private var draftID: UUID?
    @Environment(\.dismiss) private var dismiss
    init(document: EditDocument, host: HostProfile?, store: AppStore, saved: @escaping () -> Void) {
        self.document = document; self.host = host; self.store = store; self.saved = saved
        _buffer = StateObject(wrappedValue: FileEditorBuffer(text: String(decoding: document.data, as: UTF8.self)))
        _savedData = State(initialValue: document.data); _savedAttributes = State(initialValue: document.file.attributes)
        _showPreview = State(initialValue: store.isTestWorkspace && ProcessInfo.processInfo.environment["SWB_QA_SCREEN"] == "markdown-editor")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "doc.text").foregroundStyle(.teal); Text(document.file.name).font(.title3.bold()); Spacer(); Text(host == nil ? L10n.text("UTF-8 · 本地编辑") : L10n.text("UTF-8 · 远程编辑")).font(.caption).foregroundStyle(.secondary) }
            Text(document.file.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if let draft = draftToReview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("发现上次保存失败留下的本机草稿，请先恢复或明确丢弃。")) .font(.caption)
                    HStack {
                        Button(L10n.text("恢复草稿")) { buffer.restoreDraft(String(decoding: draft.edited, as: UTF8.self)); draftID = draft.id; draftToReview = nil }
                            .disabled(!draft.canRestore(hostID: host?.id, connectionKey: host?.connectionKey, path: document.file.path, current: savedData))
                            .interactionFrame("editor.restore-draft")
                        Button(L10n.text("复制草稿")) { draftClipboard.write(String(decoding: draft.edited, as: UTF8.self)) }.disabled(draft.edited.isEmpty)
                        Button(L10n.text("丢弃草稿"), role: .destructive) {
                            if confirm(L10n.text("丢弃恢复草稿？"), L10n.text("只删除本机恢复副本，不修改远端文件。")) {
                                do { try store.removeEditorDraft(host: host, path: document.file.path, identifier: draft.id); draftToReview = nil; draftID = nil }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }
                    }
                    if !draftClipboard.message.isEmpty { Text(draftClipboard.message).font(.caption).foregroundStyle(draftClipboard.failed ? .orange : .green) }
                    if !draft.canRestore(hostID: host?.id, connectionKey: host?.connectionKey, path: document.file.path, current: savedData) {
                        Text(L10n.text("文件已变化，禁止自动套用旧草稿；可复制草稿后手动核对合并。")) .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(10).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 10) {
                Button { save() } label: { Label(L10n.text("保存"), systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s").disabled(busy).help(L10n.text("保存（⌘S），不关闭编辑器"))
                    .accessibilityIdentifier("editor.save").interactionFrame("editor.save")
                Divider().frame(height: 18)
                Button { buffer.undo() } label: { Label(L10n.text("撤销"), systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z")
                    .disabled(busy || !buffer.canUndo).help(L10n.text("撤销（⌘Z）")).accessibilityIdentifier("editor.undo").interactionFrame("editor.undo")
                Button { buffer.redo() } label: { Label(L10n.text("重做"), systemImage: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(busy || !buffer.canRedo).help(L10n.text("重做（⇧⌘Z）")).accessibilityIdentifier("editor.redo").interactionFrame("editor.redo")
                Button { buffer.cut() } label: { Label(L10n.text("剪切"), systemImage: "scissors").labelStyle(.iconOnly) }
                    .disabled(busy || !buffer.hasSelection).help(L10n.text("剪切（⌘X）")).accessibilityIdentifier("editor.cut").interactionFrame("editor.cut")
                Button { buffer.copy() } label: { Label(L10n.text("复制"), systemImage: "doc.on.doc").labelStyle(.iconOnly) }
                    .disabled(!buffer.hasSelection).help(L10n.text("复制（⌘C）")).accessibilityIdentifier("editor.copy").interactionFrame("editor.copy")
                Button { buffer.paste() } label: { Label(L10n.text("粘贴"), systemImage: "doc.on.clipboard").labelStyle(.iconOnly) }
                    .disabled(busy).help(L10n.text("粘贴（⌘V）")).accessibilityIdentifier("editor.paste").interactionFrame("editor.paste")
                Button { buffer.selectAll() } label: { Label(L10n.text("全选"), systemImage: "selection.pin.in.out").labelStyle(.iconOnly) }
                    .help(L10n.text("全选（⌘A）")).accessibilityIdentifier("editor.selectAll").interactionFrame("editor.selectAll")
                Spacer()
                if ["md", "markdown"].contains((document.file.path as NSString).pathExtension.lowercased()) {
                    Toggle(L10n.text("实时 Markdown 预览"), isOn: $showPreview).toggleStyle(.checkbox).font(.caption)
                }
            }
            HSplitView {
                FileEditorTextView(buffer: buffer, editable: !busy).border(.quaternary).frame(minWidth: 260)
                if showPreview { MarkdownPreview(source: buffer.text).frame(minWidth: 240) }
            }
            if let errorMessage { ErrorBanner(message: errorMessage) { self.errorMessage = nil }.interactionFrame("editor.error") }
            HStack {
                Label(L10n.text("保存前检查文件变化，临时文件写完后原子替换。"), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("查看差异")) { showChanges = true }.disabled(busy).interactionFrame("editor.diff")
                HStack(spacing: 6) {
                    ZStack { if busy { ProgressView().controlSize(.small) } }.frame(width: 16, height: 16)
                    Text(busy ? L10n.text("正在保存…") : (showSaved ? L10n.text("已保存") : (isDirty ? L10n.text("未保存的修改") : "")))
                        .font(.caption).foregroundStyle(showSaved ? .green : .secondary)
                        .accessibilityIdentifier("editor.status").interactionFrame(showSaved ? "editor.saved" : "editor.status")
                }.frame(minWidth: 110, alignment: .leading)
                Button(L10n.text("关闭")) {
                    if !isDirty || confirm(L10n.text("放弃未保存的修改？"), L10n.text("关闭会丢弃自上次保存以来的修改，已保存的内容不受影响。")) { dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(busy).accessibilityIdentifier("editor.close").interactionFrame("editor.close")
            }
        }.padding(24).frame(width: 850, height: 620).interactiveDismissDisabled()
            .sheet(isPresented: $showChanges) { TextChangesView(original: String(decoding: savedData, as: UTF8.self), edited: buffer.text) }
            .task {
                do { draftToReview = try store.loadEditorDraft(host: host, path: document.file.path); draftID = draftToReview?.id }
                catch { errorMessage = error.localizedDescription }
            }
            .onChange(of: buffer.text) { _, _ in showSaved = false }
            .task(id: savedAt) {
                guard savedAt != nil else { return }
                do { try await Task.sleep(for: .seconds(2)); showSaved = false } catch {}
            }
    }
    private var isDirty: Bool { buffer.text != String(decoding: savedData, as: UTF8.self) }
    private func save() {
        guard !busy else { return }
        guard draftToReview == nil else { errorMessage = L10n.text("请先处理恢复草稿，避免覆盖未恢复的内容。"); return }
        guard let data = buffer.text.data(using: .utf8), data.count <= 512 * 1024 else { errorMessage = L10n.text("编辑内容超过 512 KiB，请使用终端编辑或上传文件。"); return }
        buffer.textView?.breakUndoCoalescing()
        busy = true; errorMessage = nil; showSaved = false
        let transport = store.transport; let file = document.file; let original = savedData; let expected = savedAttributes
        Task {
            defer { busy = false; buffer.focus() }
            do {
                let attributes = try await Task.detached {
                    let client = try transport.files(host); defer { client.close() }
                    try client.saveText(file.path, data: data, expected: expected, original: original)
                    return try client.stat(file.path)
                }.value
                savedData = data; savedAttributes = attributes; savedAt = Date(); showSaved = true
                do { try store.removeEditorDraft(host: host, path: file.path, identifier: draftID); draftID = nil }
                catch { errorMessage = L10n.text("文件已保存，但清理本机草稿失败：") + error.localizedDescription }
                saved()
            } catch {
                let failure = error.localizedDescription
                do {
                    let draft = try store.saveEditorDraft(host: host, path: file.path, original: original, edited: data, replacing: draftID)
                    draftID = draft.id
                    errorMessage = failure + "\n" + L10n.text("编辑内容已保存为本机私有草稿，可重试保存或下次打开时恢复。")
                } catch { errorMessage = failure + "\n" + L10n.text("本机草稿保存失败，请勿关闭编辑器：") + error.localizedDescription }
            }
        }
    }
}
