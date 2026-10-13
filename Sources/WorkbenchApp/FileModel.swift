import Foundation
import AppKit
import SwiftUI
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class FileModel: ObservableObject {
    let id = UUID()
    @Published var path = "."
    @Published var pathInput = "."
    @Published var files: [RemoteFile] = []
    @Published var selection: Set<String> = []
    @Published var busy = false
    @Published var previewBusy = false
    @Published var errorMessage: String?
    @Published var previewFile: RemoteFile?
    @Published var previewData = Data()
    @Published var previewOffset: UInt64 = 0
    @Published var previewImage: NSImage?
    @Published var filter = ""
    @Published var showHidden = false
    @Published var followLog = false
    let host: HostProfile?
    let transport: SSHTransport
    private var navigation = CancellationFlag()
    private var previewCancellation = CancellationFlag()
    private var generation = UUID()
    private var hasLoaded = false
    let previewLimit = 512 * 1024
    init(host: HostProfile?, store: AppStore) { self.host = host; transport = store.transport }
    var visibleFiles: [RemoteFile] { files.filter { (showHidden || !$0.name.hasPrefix(".")) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) } }
    var selectedFiles: [RemoteFile] { visibleFiles.filter { selection.contains($0.path) } }
    var selectedFile: RemoteFile? { selectedFiles.count == 1 ? selectedFiles.first : nil }
    var selectedEndpoints: [FileEndpoint] { selectedFiles.map { FileEndpoint(hostID: host?.id, path: $0.path) } }
    var previewText: String { String(decoding: previewData, as: UTF8.self) }
    var binaryPreview: Bool { previewData.contains(0) && previewImage == nil }
    var editable: Bool { guard let file = previewFile else { return false }; return !file.attributes.isDirectory && !file.attributes.isSymbolicLink && file.attributes.size <= previewLimit && previewOffset == 0 && String(data: previewData, encoding: .utf8) != nil && !binaryPreview && previewImage == nil }
    func loadIfNeeded(_ initialPath: String? = nil) {
        if !hasLoaded && !busy { load(initialPath ?? path) }
    }
    func load(_ target: String? = nil) {
        navigation.cancel(); navigation = CancellationFlag(); let cancellation = navigation
        let target = target ?? path; let transport = transport; let host = host
        busy = true; errorMessage = nil
        Task {
            do {
                let result = try await Task.detached { () -> (String, [RemoteFile]) in
                    let client = try transport.files(host, cancellation: cancellation); defer { client.close() }
                    let canonical = try client.realpath(target)
                    return (canonical, try client.list(canonical))
                }.value
                guard !cancellation.isCancelled else { return }
                if path != result.0 { previewCancellation.cancel(); generation = UUID(); previewBusy = false; filter = ""; selection = [] }
                path = result.0; pathInput = result.0; files = result.1; busy = false; hasLoaded = true
                selection.formIntersection(Set(files.map(\.path)))
                if selection.count != 1 { previewFile = nil; previewData = Data(); followLog = false }
            } catch { if !cancellation.isCancelled { errorMessage = error.localizedDescription; busy = false } }
        }
    }
    func activate(_ file: RemoteFile) {
        followLog = false
        if file.attributes.isDirectory { load(file.path) }
        else { selection = [file.path]; preview(file) }
    }
    func preview(_ file: RemoteFile, offset: UInt64 = 0, tail: Bool = false) {
        previewCancellation.cancel(); previewCancellation = CancellationFlag(); let cancellation = previewCancellation
        let identifier = UUID(); generation = identifier
        previewFile = file; previewBusy = true
        if file.attributes.isDirectory { previewData = Data(); previewImage = nil; previewBusy = false; return }
        let transport = transport; let host = host; let limit = previewLimit
        Task {
            do {
                let result = try await Task.detached { () -> (Data, FileAttributes, UInt64) in
                    let client = try transport.files(host, cancellation: cancellation); defer { client.close() }
                    let attributes = try client.stat(file.path, followLinks: true)
                    guard attributes.isRegularFile else { throw WorkbenchError.message("不预览设备、管道或套接字。") }
                    let position = tail ? (attributes.size > UInt64(limit) ? attributes.size - UInt64(limit) : 0) : min(offset, attributes.size)
                    let imageType = ["png", "jpg", "jpeg", "gif", "tiff", "webp", "heic"].contains((file.path as NSString).pathExtension.lowercased())
                    if imageType, attributes.size <= 8 * 1024 * 1024 {
                        return (try client.preview(file.path, offset: 0, limit: Int(attributes.size)), attributes, 0)
                    }
                    return (try client.preview(file.path, offset: position, limit: limit), attributes, position)
                }.value
                guard generation == identifier, !cancellation.isCancelled else { return }
                previewData = result.0; previewOffset = result.2
                var updated = file; updated.attributes = result.1
                if file.attributes.isSymbolicLink { updated.attributes.permissions = file.attributes.permissions }
                previewFile = updated
                previewImage = NSImage(data: result.0)
                previewBusy = false
            } catch { if generation == identifier && !cancellation.isCancelled { errorMessage = errorMessage ?? error.localizedDescription; previewBusy = false } }
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
                if !result.1.isEmpty { errorMessage = "已删除 \(result.0.count) 项，\(result.1.count) 项未能完成（目录可能已部分删除）：\n" + result.1.prefix(5).joined(separator: "\n") }
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
        if busy { hasLoaded = false }
        navigation.cancel(); previewCancellation.cancel(); generation = UUID()
        busy = false; previewBusy = false; followLog = false
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
    @ViewState private var text: String
    @ViewState private var busy = false
    @ViewState private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    init(document: EditDocument, host: HostProfile?, store: AppStore, saved: @escaping () -> Void) {
        self.document = document; self.host = host; self.store = store; self.saved = saved; _text = State(initialValue: String(decoding: document.data, as: UTF8.self))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "doc.text").foregroundStyle(.teal); Text(document.file.name).font(.title3.bold()); Spacer(); Text(host == nil ? "UTF-8 · 本地编辑" : "UTF-8 · 远程编辑").font(.caption).foregroundStyle(.secondary) }
            Text(document.file.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).border(.quaternary).disabled(busy)
            if let errorMessage { ErrorBanner(message: errorMessage) { self.errorMessage = nil } }
            HStack {
                Label("保存前检查文件变化，临时文件写完后原子替换。", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("取消") { if text == String(decoding: document.data, as: UTF8.self) || confirm("放弃未保存的修改？", "远端文件尚未修改。") { dismiss() } }.disabled(busy)
                Button(host == nil ? "保存文件" : "保存到远端") { save() }.buttonStyle(.borderedProminent).keyboardShortcut("s").disabled(busy)
            }
        }.padding(24).frame(width: 850, height: 620).interactiveDismissDisabled()
    }
    private func save() {
        guard let data = text.data(using: .utf8), data.count <= 512 * 1024 else { errorMessage = "编辑内容超过 512 KiB，请使用终端编辑或上传文件。"; return }
        busy = true; let transport = store.transport; let file = document.file
        Task {
            do {
                let original = document.data
                try await Task.detached { let client = try transport.files(host); defer { client.close() }; try client.saveText(file.path, data: data, expected: file.attributes, original: original) }.value
                saved(); dismiss()
            } catch { busy = false; errorMessage = error.localizedDescription }
        }
    }
}
