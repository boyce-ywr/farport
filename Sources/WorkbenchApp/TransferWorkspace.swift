import SwiftUI
import AppKit
import WorkbenchCore
import OpenSSHBackend

struct TransferWorkspace: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(L10n.text("传输")).font(.title2.weight(.semibold)); Text(L10n.text("本机上传下载与跨主机传输，共用一个可靠队列。")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(L10n.text("清除失败 / 已取消")) { store.clearTransferRecords(abnormalOnly: true) }.disabled(!store.transfers.contains { [.failed, .cancelled].contains($0.status) }).help(L10n.text("只清除记录，不删除源文件、目标或断点文件"))
                Button(L10n.text("清除已结束记录")) { store.clearTransferRecords() }.disabled(!store.transfers.contains { $0.status.canClearRecord }).help(L10n.text("清除已完成、失败和已取消记录，保留进行中、待确认及暂停任务"))
            }
            HStack(spacing: 16) {
                Label(L10n.text("最多 2 路并行"), systemImage: "arrow.triangle.branch")
                Label(L10n.text("有界内存流式中转"), systemImage: "memorychip")
                Label(L10n.text("恢复前验证断点"), systemImage: "checkmark.shield")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            if store.transfers.isEmpty {
                VStack(spacing: 16) { Image(systemName: "arrow.left.arrow.right").font(.system(size: 35, weight: .light)).foregroundStyle(.teal); Text(L10n.text("文件已准备好出发")).font(.title3.weight(.medium)); Text(L10n.text("在文件工作区选择文件，然后点击“传输到…”。\n也可以将本地文件拖入远程文件列表。")).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) { ForEach(store.transfers) { job in TransferRow(job: job, store: store) } }
                }
            }
            HStack(spacing: 7) { Image(systemName: "info.circle"); Text(L10n.text("Mac 休眠或离线时传输会暂停或失败。恢复连接后点击继续；已有内容会先校验，不会盲目追加。")) }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(20)
    }
}

struct TransferRow: View {
    let job: TransferJob
    @ObservedObject var store: AppStore
    @ViewState private var previousBytes: UInt64 = 0
    @ViewState private var previousTime = Date()
    @ViewState private var speed: Double = 0
    @ViewState private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: job.source.isLocal ? "arrow.up.doc" : (job.destination.isLocal ? "arrow.down.doc" : "arrow.left.arrow.right"))
                    .font(.system(size: 16)).foregroundStyle(.teal).frame(width: 30, height: 30).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if job.isMove { Text(L10n.text("移动")).font(.system(size: 10, weight: .medium)).foregroundStyle(.teal) }
                        Text(job.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    HStack(spacing: 5) { Text(endpointName(job.source)); Image(systemName: "arrow.right"); Text(endpointName(job.destination)) }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Text(job.status == .completed ? bytes(job.totalBytes) : "\(bytes(job.completedBytes)) / \(bytes(job.totalBytes))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Text(job.status.title).font(.system(size: 11, weight: .medium)).foregroundStyle(statusColor).frame(minWidth: 56, alignment: .trailing)
                if TransferFileLocation.url(for: job) != nil {
                    Button {
                        do { try TransferFileLocation.reveal(job) } catch { store.errorMessage = error.localizedDescription }
                    } label: { Image(systemName: "folder") }
                        .help(job.destination.isLocal ? L10n.text("在 Finder 中显示目标文件") : L10n.text("在 Finder 中显示本机源文件"))
                        .accessibilityIdentifier("transfer.reveal.\(job.id)").interactionFrame("transfer.reveal.\(job.id)")
                }
                if job.status == .running || job.status == .queued { Button { store.pause(job) } label: { Image(systemName: "pause.fill") }.help(L10n.text("暂停并保留断点")) }
                if job.status == .paused || job.status == .failed { Button { store.resume(job) } label: { Image(systemName: "play.fill") }.help(L10n.text("校验并继续")) }
                if [.running, .queued, .paused, .awaitingConfirmation, .failed].contains(job.status) {
                    Button {
                        if confirm(job.isMove ? L10n.text("停止此移动？") : L10n.text("取消此传输？"), job.isMove ? L10n.text("已完成的移动不会撤销；保留源、目标和暂存文件，可从此任务继续。") : L10n.text(".swb-* 暂存条目会保留在目标目录，便于检查；原始文件不会被删除。")) { store.cancel(job) }
                    } label: { Image(systemName: "xmark") }.help(job.isMove ? L10n.text("停止并保留进度") : L10n.text("取消"))
                }
                if job.status.canClearRecord { Button { store.clearTransferRecords(identifier: job.id) } label: { Image(systemName: "trash") }.help(L10n.text("仅清除此记录，不删除文件")) }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }.help(L10n.text("任务详情"))
            }.buttonStyle(.borderless)
            if !job.status.canClearRecord { ProgressView(value: job.fraction).tint(statusColor).controlSize(.small) }
            if job.status != .completed || expanded {
                HStack {
                    Text(job.message).font(.system(size: 11)).lineLimit(expanded ? nil : 1)
                    Spacer()
                    if job.status == .running && speed > 0 { Text("\(bytes(UInt64(speed)))/s").font(.system(size: 11, design: .monospaced)) }
                }.foregroundStyle(job.status == .failed ? Color.orange : .secondary)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("源：\(job.source.path)")); Text(L10n.text("目标：\(job.destination.path)")); Text(L10n.text("任务：\(job.id.uuidString)"))
                    if job.status != .completed { Text(L10n.text("断点后缀：.swb-\(job.id.uuidString).part")) }
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(.horizontal, 12).padding(.vertical, 10).background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary.opacity(0.5)))
            .onAppear { previousBytes = job.completedBytes; previousTime = Date() }
            .onChange(of: job.completedBytes) { _, current in
                let interval = Date().timeIntervalSince(previousTime)
                if current >= previousBytes && interval > 0.1 { speed = Double(current - previousBytes) / interval; previousBytes = current; previousTime = Date() }
                else if current < previousBytes { previousBytes = current; previousTime = Date(); speed = 0 }
            }
    }
    private var statusColor: Color { job.status == .failed ? .orange : (job.status == .cancelled ? .secondary : .teal) }
    private func endpointName(_ endpoint: FileEndpoint) -> String { endpoint.isLocal ? L10n.text("此 Mac") : (store.hosts.first { $0.id == endpoint.hostID }?.name ?? L10n.text("已移除主机")) }
}

enum TransferFileLocation {
    static func url(for job: TransferJob) -> URL? {
        guard job.status == .completed else { return nil }
        let endpoint = job.destination.isLocal ? job.destination : job.source
        guard endpoint.isLocal, endpoint.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: endpoint.path)
    }
    static func reveal(_ job: TransferJob) throws {
        guard let url = url(for: job), FileManager.default.fileExists(atPath: url.path) else {
            throw WorkbenchError.message(L10n.text("本机文件已移动或删除，无法在 Finder 中定位。"))
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

struct TransferTray: View {
    @ObservedObject var store: AppStore
    let expand: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.teal)
            if let job = store.transfers.first(where: { $0.status == .running }) ?? store.transfers.first {
                VStack(alignment: .leading, spacing: 4) { Text(job.name).font(.system(size: 11, weight: .medium)); Text("\(job.status.title) · \(bytes(job.completedBytes)) / \(bytes(job.totalBytes))").font(.system(size: 10)).foregroundStyle(.secondary) }
                ProgressView(value: job.fraction).frame(maxWidth: 200)
            } else { Text(L10n.text("暂无传输任务")).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Button(L10n.text("查看全部"), action: expand).font(.caption)
        }.padding(.horizontal, 20).padding(.vertical, 13)
    }
}

struct TransferComposer: View {
    let sources: [FileEndpoint]
    @ObservedObject var store: AppStore
    @ViewState private var target = "local"
    @ViewState private var folder = ""
    @ViewState private var filename = ""
    @ViewState private var overwrite = false
    @ViewState private var resolving = false
    @ViewState private var errorMessage: String?
    @ViewState private var showFolderPicker = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L10n.text("传输文件"), systemImage: "arrow.left.arrow.right").font(.title2.bold()).foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 6) {
                Text(sources.count == 1 ? (sources[0].path as NSString).lastPathComponent : L10n.text("批量传输 \(sources.count) 个文件 / 文件夹")).font(.headline)
                ForEach(Array(sources.prefix(5).enumerated()), id: \.offset) { _, source in Text(source.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled) }
                if sources.count > 5 { Text(L10n.text("另有 \(sources.count - 5) 项")).font(.caption).foregroundStyle(.secondary) }
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            Form {
                Picker(L10n.text("目标"), selection: $target) { Text(L10n.text("此 Mac")).tag("local"); ForEach(store.hosts) { Text($0.name).tag($0.id.uuidString) } }
                HStack { TextField(L10n.text("目标文件夹"), text: $folder); Button(L10n.text("选择…")) { chooseFolder() } }
                if sources.count == 1 { TextField(L10n.text("保存名称"), text: $filename) }
                Toggle(L10n.text("允许覆盖同名文件"), isOn: $overwrite)
            }.textFieldStyle(.roundedBorder)
            Text(overwrite ? L10n.text("已有目标文件会在新文件写完后原子替换。目录会合并，不会删除目标目录中的其他文件。") : L10n.text("发现同名目标时会等待你确认，不会直接覆盖。远端互传使用 Mac 流式中转。")).font(.system(size: 11)).foregroundStyle(overwrite ? Color.orange : .secondary).lineSpacing(4)
            if let errorMessage { ErrorBanner(message: errorMessage) { self.errorMessage = nil } }
            HStack { if resolving { ProgressView().controlSize(.small) }; Spacer(); Button(L10n.text("取消")) { dismiss() }; Button(L10n.text("加入传输队列")) { queue() }.buttonStyle(.borderedProminent).disabled(sources.isEmpty || resolving || folder.isEmpty || (sources.count == 1 && !RemotePath.validName(filename))) }
        }.padding(28).frame(width: 570)
            .onAppear { filename = ((sources.first?.path ?? "") as NSString).lastPathComponent; target = store.hosts.first(where: { $0.id != sources.first?.hostID })?.id.uuidString ?? "local"; resolveFolder() }
            .onChange(of: target) { _, _ in resolveFolder() }
            .sheet(isPresented: $showFolderPicker) { if let host = targetHost { RemoteFolderPicker(host: host, store: store, initial: folder) { folder = $0; showFolderPicker = false } } }
    }
    private var targetHost: HostProfile? { store.hosts.first { $0.id.uuidString == target } }
    private func resolveFolder() {
        folder = ""; errorMessage = nil
        if let host = targetHost {
            resolving = true; let selected = target; let transport = store.transport
            Task {
                do { let resolved = try await Task.detached { let client = try transport.sftp(host); defer { client.close() }; return try client.realpath() }.value; if selected == target { folder = resolved; resolving = false } }
                catch { if selected == target { resolving = false; errorMessage = error.localizedDescription } }
            }
        } else { folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? FileManager.default.homeDirectoryForCurrentUser.path; resolving = false }
    }
    private func chooseFolder() {
        if targetHost != nil { showFolderPicker = true }
        else { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; if panel.runModal() == .OK { folder = panel.url?.path ?? folder } }
    }
    private func queue() {
        guard folder.hasPrefix("/"), !folder.contains("\0") else { errorMessage = L10n.text("请输入绝对目录路径。"); return }
        do {
            if sources.count == 1, let source = sources.first, filename != (source.path as NSString).lastPathComponent {
                let destination = FileEndpoint(hostID: targetHost?.id, path: RemotePath.join(folder, filename))
                guard destination != source else { throw WorkbenchError.message(L10n.text("源和目标不能是同一个路径。")) }
                store.queue(TransferJob(source: source, destination: destination, overwrite: overwrite))
            } else {
                try store.queueFiles(sources, to: FileEndpoint(hostID: targetHost?.id, path: folder), overwrite: overwrite)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct RemoteFolderPicker: View {
    @StateObject private var model: FileModel
    let selected: (String) -> Void
    let initial: String
    @Environment(\.dismiss) private var dismiss
    init(host: HostProfile, store: AppStore, initial: String, selected: @escaping (String) -> Void) { _model = StateObject(wrappedValue: FileModel(host: host, store: store)); self.initial = initial; self.selected = selected }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("选择远端文件夹")).font(.title3.bold())
            HStack { Button { model.load(RemotePath.parent(model.path)) } label: { Image(systemName: "arrow.up") }; TextField(L10n.text("路径"), text: $model.pathInput).onSubmit { model.load(model.pathInput) }; if model.busy { ProgressView().controlSize(.small) } }
            List(model.files.filter { $0.attributes.isDirectory }) { file in Button { model.load(file.path) } label: { Label(file.name, systemImage: "folder.fill").foregroundStyle(.primary) }.buttonStyle(.plain) }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack { Text(model.path).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L10n.text("取消")) { dismiss() }; Button(L10n.text("选择此文件夹")) { selected(model.path) }.buttonStyle(.borderedProminent).disabled(model.busy) }
        }.padding(22).frame(width: 540, height: 450).onAppear { model.load(initial) }.onDisappear { model.stop() }
    }
}
