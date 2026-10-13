import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WorkbenchCore

struct FileTransferSelection: Identifiable {
    let id = UUID()
    let sources: [FileEndpoint]
}

struct FileWorkspace: View {
    let host: HostProfile?
    @ObservedObject var store: AppStore
    @StateObject private var model: FileModel
    @ViewState private var transferSelection: FileTransferSelection?
    @ViewState private var editDocument: EditDocument?
    @ViewState private var dropTarget = false
    init(host: HostProfile?, store: AppStore) { self.host = host; self.store = store; _model = StateObject(wrappedValue: FileModel(host: host, store: store)) }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let error = model.errorMessage { ErrorBanner(message: error) { model.errorMessage = nil }.padding(.horizontal, 18).padding(.bottom, 8) }
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack { Image(systemName: "magnifyingglass").foregroundStyle(.tertiary); TextField("筛选当前目录", text: $model.filter).textFieldStyle(.plain); Spacer(); Toggle("隐藏文件", isOn: $model.showHidden).toggleStyle(.checkbox) }.font(.system(size: 11)).padding(14)
                    Table(model.visibleFiles, selection: $model.selection) {
                        TableColumn("名称") { file in
                            HStack(spacing: 9) {
                                Image(systemName: fileIcon(file)).foregroundStyle(file.attributes.isDirectory ? Color.teal : .secondary).font(.system(size: 15))
                                Text(file.name)
                            }.font(.system(size: 12)).lineLimit(1)
                                .help(file.attributes.isDirectory ? "单击选中，双击打开文件夹" : file.name)
                        }.width(min: 160, ideal: 260)
                        TableColumn("大小") { file in Text(file.attributes.isDirectory ? "—" : bytes(file.attributes.size)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }.width(min: 55, ideal: 70)
                        TableColumn("修改时间") { file in Text(file.attributes.date, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()).font(.system(size: 10)).foregroundStyle(.secondary) }.width(min: 100, ideal: 120)
                        TableColumn("权限") { file in Text(file.attributes.permissionText).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }.width(40)
                    }.alternatingRowBackgrounds(.disabled)
                        .background(FileKeyboardCommands(copy: { copyFiles(model.selectedFiles) }, paste: { pasteFiles() }, selectAll: { model.selection = Set(model.visibleFiles.map(\.path)) }).frame(width: 0, height: 0))
                        .contextMenu(forSelectionType: String.self) { identifiers in
                            let selected = model.files.filter { identifiers.contains($0.path) }
                            if selected.count == 1, let file = selected.first { fileActions(file) }
                            else if !selected.isEmpty { batchActions(selected) }
                        } primaryAction: { identifiers in
                            if let file = model.files.first(where: { identifiers.contains($0.path) }) { model.activate(file) }
                        }
                        .onChange(of: model.selection) { _, _ in model.followLog = false; if let file = model.selectedFile { model.preview(file) } else { model.previewFile = nil } }
                        .onChange(of: model.filter) { _, _ in model.selection.formIntersection(Set(model.visibleFiles.map(\.path))) }
                    Divider()
                    HStack { Text("\(model.visibleFiles.count) 项 · 已选 \(model.selectedFiles.count) 项"); Spacer(); Text("⌘ / ⇧ 多选 · ⌘C 复制 · ⌘V 粘贴") }.font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
                }.frame(minWidth: 430)
                preview.frame(minWidth: 270, idealWidth: 330, maxWidth: 480)
            }
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).strokeBorder(.teal, style: StrokeStyle(lineWidth: 2, dash: [7])).padding(8).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            for provider in providers {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async { queueUpload(url) }
                    }
                }
            }
            return !providers.isEmpty
        }
        .sheet(item: $transferSelection) { selection in TransferComposer(sources: selection.sources, store: store) }
        .sheet(item: $editDocument) { document in RemoteEditor(document: document, host: host, store: store) { model.load(); if let file = model.previewFile { model.preview(file) } } }
        .task {
            let qaDirectory = store.isTestWorkspace && ProcessInfo.processInfo.environment["SWB_QA_OUTPUT"] != nil
                ? (host == nil ? ProcessInfo.processInfo.environment["SWB_QA_LOCAL_DIRECTORY"] : "/home/tester/workspace") : nil
            model.load(qaDirectory)
            if store.isTestWorkspace && ProcessInfo.processInfo.environment["SWB_QA_FILE_NAVIGATION"] == "1" {
                await verifyDirectoryActivation()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled && model.followLog, let file = model.previewFile { model.preview(file, tail: true) }
            }
        }
        .onDisappear { model.stop() }
        .onChange(of: store.transfers.filter { $0.status == .completed }.map(\.id)) { _, _ in if !model.busy { model.load() } }
        .onChange(of: model.files) { _, files in
            if store.isTestWorkspace, ProcessInfo.processInfo.environment["SWB_QA_SCREEN"] == "files", model.selection.isEmpty,
               let path = files.first(where: { $0.name == "README.md" })?.path {
                model.selection = [path]
            }
        }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.load(RemotePath.parent(model.path)) } label: { Image(systemName: "arrow.up") }.help("上一级目录")
            Button { model.load(".") } label: { Image(systemName: "house") }.help("远端主目录")
            HStack { Image(systemName: host == nil ? "internaldrive" : "folder").foregroundStyle(.teal); TextField("目录路径", text: $model.pathInput).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).onSubmit { model.load(model.pathInput) } }.padding(8).background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
            if model.busy { ProgressView().controlSize(.small) }
            Button { model.load() } label: { Image(systemName: "arrow.clockwise") }.help("刷新目录")
            Menu {
                Button("新建文件夹") {
                    if let name = promptText("新建文件夹"), RemotePath.validName(name) { let path = RemotePath.join(model.path, name); model.perform { try $0.mkdir(path) } }
                }
                Button("新建文本文件") {
                    if let name = promptText("新建文本文件", initial: "untitled.txt"), RemotePath.validName(name) {
                        let path = RemotePath.join(model.path, name); model.perform { try $0.createFile(path) }
                    }
                }
            } label: { Image(systemName: "folder.badge.plus") }.menuStyle(.borderlessButton).frame(width: 25)
            Menu {
                Button("复制所选 \(model.selectedFiles.count) 项") { copyFiles(model.selectedFiles) }.disabled(model.selectedFiles.isEmpty)
                Button("粘贴 \(store.fileClipboard.count) 项到此目录") { pasteFiles() }.disabled(store.fileClipboard.isEmpty || model.busy)
                Button(host == nil ? "从本机选择文件…" : "上传本地文件…") { let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; if panel.runModal() == .OK { queueSources(panel.urls.map { FileEndpoint(path: $0.path) }) } }
            } label: { Image(systemName: "doc.on.doc") }.menuStyle(.borderlessButton).frame(width: 26)
            Button { transferSelection = FileTransferSelection(sources: model.selectedEndpoints) } label: { Label("传输到…", systemImage: "arrow.left.arrow.right") }.buttonStyle(.borderedProminent).disabled(model.selectedFiles.isEmpty)
        }.buttonStyle(.borderless).padding(16)
    }
    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("快速预览").font(.system(size: 11, weight: .semibold)); Spacer(); if model.previewBusy { ProgressView().controlSize(.small) }; if model.editable { Button("编辑") { if let file = model.previewFile { editDocument = EditDocument(file: file, data: model.previewData) } }.font(.caption) } }.padding(16)
            Divider()
            if let file = model.previewFile {
                VStack(alignment: .leading, spacing: 7) {
                    Label(file.name, systemImage: fileIcon(file)).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(file.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack { Text(bytes(file.attributes.size)); Text("权限 \(file.attributes.permissionText)") }.font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(16)
                Divider()
                if file.attributes.isDirectory {
                    VStack(spacing: 15) { Image(systemName: "folder.fill").font(.system(size: 58)).foregroundStyle(.teal.opacity(0.7)); Button("打开文件夹") { model.load(file.path) } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image = model.previewImage {
                    ScrollView { Image(nsImage: image).resizable().scaledToFit().padding(16) }
                } else if model.binaryPreview {
                    VStack(alignment: .leading, spacing: 12) { Label("二进制文件", systemImage: "doc.zipper"); Text("可下载或传输到另一台主机。不会把二进制内容作为文本写回。").font(.caption).foregroundStyle(.secondary); Text(model.previewData.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }.padding(18)
                    Spacer()
                } else {
                    ScrollView([.horizontal, .vertical]) { Text(model.previewText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineSpacing(5).frame(maxWidth: .infinity, alignment: .topLeading).padding(16) }
                    Divider()
                    HStack {
                        Button { model.followLog = false; model.preview(file, offset: model.previewOffset > UInt64(model.previewLimit) ? model.previewOffset - UInt64(model.previewLimit) : 0) } label: { Image(systemName: "chevron.left") }.disabled(model.previewOffset == 0)
                        Text("\(bytes(model.previewOffset)) / \(bytes(file.attributes.size))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        Button { model.followLog = false; model.preview(file, offset: model.previewOffset + UInt64(model.previewData.count)) } label: { Image(systemName: "chevron.right") }.disabled(model.previewOffset + UInt64(model.previewData.count) >= file.attributes.size)
                        Spacer()
                        Toggle("跟随", isOn: $model.followLog).toggleStyle(.checkbox).font(.system(size: 10)).help("每两秒读取文件末尾，适用于日志")
                    }.buttonStyle(.borderless).padding(12)
                }
            } else {
                VStack(spacing: 13) {
                    Image(systemName: model.selectedFiles.count > 1 ? "doc.on.doc" : "doc.text.magnifyingglass").font(.system(size: 33, weight: .light)).foregroundStyle(.tertiary)
                    Text(model.selectedFiles.count > 1 ? "已选择 \(model.selectedFiles.count) 项" : "选择文件，即刻预览").font(.system(size: 12)).foregroundStyle(.secondary)
                    if model.selectedFiles.count > 1 { Button("复制所选项目") { copyFiles(model.selectedFiles) }; Button("批量传输…") { transferSelection = FileTransferSelection(sources: model.selectedEndpoints) } }
                    Text("文本 · 图片 · 文件夹").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(.quaternary.opacity(0.09))
    }
    @ViewBuilder private func fileActions(_ file: RemoteFile) -> some View {
        if file.attributes.isDirectory { Button("打开") { model.load(file.path) } }
        Button("复制") { copyFiles([file]) }
        Button("传输到…") { transferSelection = FileTransferSelection(sources: [FileEndpoint(hostID: host?.id, path: file.path)]) }
        Button("下载…") {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "选择保存目录"
            if panel.runModal() == .OK, let directory = panel.url { do { try store.queueFiles([FileEndpoint(hostID: host?.id, path: file.path)], to: FileEndpoint(path: directory.path)) } catch { model.errorMessage = error.localizedDescription } }
        }
        Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string) }
        Divider()
        Button("重命名") { if let name = promptText("重命名", initial: file.name), RemotePath.validName(name) { let destination = RemotePath.join(model.path, name); model.perform { try $0.rename(file.path, to: destination) } } }
        Button("修改权限") { if let text = promptText("修改权限", detail: "输入三位八进制权限，例如 644 或 755。", initial: file.attributes.permissionText), text.count == 3, let mode = UInt32(text, radix: 8), mode <= 0o777 { model.perform { try $0.chmod(file.path, permissions: mode) } } }
        Button("删除…", role: .destructive) { if confirm("永久删除“\(file.name)”？", "远程删除不经过 Mac 废纸篓。文件夹中的内容也会被删除，无法撤销。") { model.perform { try $0.removeRecursively(file.path) } } }
    }
    @ViewBuilder private func batchActions(_ files: [RemoteFile]) -> some View {
        Button("复制 \(files.count) 项") { copyFiles(files) }
        Button("传输 \(files.count) 项到…") { transferSelection = FileTransferSelection(sources: files.map { FileEndpoint(hostID: host?.id, path: $0.path) }) }
    }
    private func copyFiles(_ files: [RemoteFile]) {
        store.fileClipboard = files.map { FileEndpoint(hostID: host?.id, path: $0.path) }
    }
    private func pasteFiles() { queueSources(store.fileClipboard) }
    private func queueSources(_ sources: [FileEndpoint]) {
        guard !model.busy, model.path.hasPrefix("/") else { return }
        do { try store.queueFiles(sources, to: FileEndpoint(hostID: host?.id, path: model.path)) }
        catch { model.errorMessage = error.localizedDescription }
    }
    private func queueUpload(_ url: URL) { queueSources([FileEndpoint(path: url.path)]) }
    @MainActor private func verifyDirectoryActivation() async {
        for _ in 0..<100 {
            if !model.busy && model.path == "/home/tester/workspace" { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let table = findTable(child) { return table } }
            return nil
        }
        guard let row = model.visibleFiles.firstIndex(where: { $0.name == "projects" && $0.attributes.isDirectory }),
              let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let table = findTable(content), let window = table.window else {
            fputs("FAIL · 找不到真实远程目录表格\n", stderr); exit(1)
        }
        table.scrollRowToVisible(row)
        let rectangle = table.rect(ofRow: row)
        let position = table.convert(NSPoint(x: rectangle.minX + 60, y: rectangle.midY), to: nil)
        for click in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: click, clickCount: click, pressure: type == .leftMouseDown ? 1 : 0) else { exit(1) }
                NSApp.postEvent(event, atStart: false)
                try? await Task.sleep(for: .milliseconds(50))
            }
            if click == 1 {
                guard model.path == "/home/tester/workspace", !model.busy,
                      model.selection == ["/home/tester/workspace/projects"] else {
                    fputs("FAIL · 单击目录名称应只选中，不应进入文件夹\n", stderr); exit(1)
                }
                print("PASS · 单击目录名称只选中，不改变目录")
            }
        }
        for _ in 0..<100 {
            if model.path == "/home/tester/workspace/projects" && !model.busy {
                print("PASS · 真实表格目录双击进入子目录")
                if ProcessInfo.processInfo.environment["SWB_QA_BATCH_COPY"] == "1" { await verifyBatchCopy(table: table, window: window) }
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        fputs("FAIL · 真实表格目录双击未导航，当前路径：\(model.path)，选中行：\(table.selectedRow)，激活回调：\(String(describing: table.doubleAction))\n", stderr)
        exit(1)
    }
    @MainActor private func verifyBatchCopy(table: NSTableView, window: NSWindow) async {
        func sendShortcut(_ character: String, code: UInt16) async {
            window.makeFirstResponder(table)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                                               isARepeat: false, keyCode: code) { NSApp.postEvent(event, atStart: false) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        model.load("/home/tester/workspace")
        for _ in 0..<100 { if !model.busy && model.path == "/home/tester/workspace" { break }; try? await Task.sleep(for: .milliseconds(100)) }
        await sendShortcut("a", code: 0)
        guard model.selectedFiles.count == model.visibleFiles.count, model.selectedFiles.count > 1 else { fputs("FAIL · ⌘A 未选中多个文件\n", stderr); exit(1) }
        let count = model.selectedFiles.count
        await sendShortcut("c", code: 8)
        guard store.fileClipboard.count == count else { fputs("FAIL · ⌘C 未复制全部选中项目\n", stderr); exit(1) }
        let destination = "/home/tester/ui-batch-" + UUID().uuidString
        let transport = store.transport; let host = host
        do {
            try await Task.detached { let client = try transport.files(host); defer { client.close() }; try client.mkdir(destination) }.value
        } catch { fputs("FAIL · 创建隔离目标目录失败\n", stderr); exit(1) }
        model.load(destination)
        for _ in 0..<100 { if !model.busy && model.path == destination { break }; try? await Task.sleep(for: .milliseconds(100)) }
        await sendShortcut("v", code: 9)
        for _ in 0..<200 {
            let batch = store.transfers.filter { $0.destination.path.hasPrefix(destination + "/") }
            if batch.count == count && batch.allSatisfy({ $0.status == .completed }) {
                print("PASS · ⌘A 多选、⌘C 复制、⌘V 批量粘贴文件与目录")
                return
            }
            if batch.contains(where: { $0.status == .failed }) { fputs("FAIL · 批量粘贴出现传输失败\n", stderr); exit(1) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        fputs("FAIL · 批量粘贴没有完成\n", stderr); exit(1)
    }
}

func bytes(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(count, UInt64(Int64.max))), countStyle: .file) }
func fileIcon(_ file: RemoteFile) -> String {
    if file.attributes.isDirectory { return "folder.fill" }
    if file.attributes.isSymbolicLink { return "link" }
    let ext = (file.name as NSString).pathExtension.lowercased()
    if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) { return "photo" }
    if ["zip", "gz", "tar", "bin"].contains(ext) { return "doc.zipper" }
    if ["json", "yaml", "yml", "toml", "xml"].contains(ext) { return "curlybraces" }
    return "doc.text"
}
