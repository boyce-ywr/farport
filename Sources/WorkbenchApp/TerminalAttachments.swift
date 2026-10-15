import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WorkbenchCore
import OpenSSHBackend

struct TerminalAttachmentPayload {
    let files: [URL]
    let temporaryDirectory: URL?
    static func read(_ pasteboard: NSPasteboard, stagingRoot: URL) throws -> TerminalAttachmentPayload? {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            return TerminalAttachmentPayload(files: files, temporaryDirectory: nil)
        }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return nil }
        guard data.count <= 128 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, Int64(width) * Int64(height) <= 64_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WorkbenchError.message(L10n.text("剪贴板图像无效或过大，请通过文件上传。")) }
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("clipboard-" + UUID().uuidString.lowercased() + ".png")
        guard let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            try? FileManager.default.removeItem(at: directory); throw WorkbenchError.message(L10n.text("无法保存剪贴板图片。"))
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { try? FileManager.default.removeItem(at: directory); throw WorkbenchError.message(L10n.text("剪贴板图片编码失败。")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return TerminalAttachmentPayload(files: [file], temporaryDirectory: directory)
    }
}

@MainActor
final class TerminalAttachmentDraft: ObservableObject, Identifiable {
    let id = UUID()
    let session: TerminalSession
    let payload: TerminalAttachmentPayload
    let identity: AttachmentDeliveryIdentity
    private weak var workspace: Workspace?
    @Published var directory = ""
    @Published var preparing = true
    @Published var running = false
    @Published var inserting = false
    @Published var progress: Double = 0
    @Published var status = L10n.text("正在确认目标…")
    @Published var failure: String?
    @Published var result: UploadedAttachments?
    @Published var inserted = false
    @Published var target: TmuxTarget?
    private var cancellation = CancellationFlag()
    private var disposed = false
    private let transport: SSHTransport
    init(session: TerminalSession, payload: TerminalAttachmentPayload, workspace: Workspace) {
        self.session = session; self.payload = payload; self.workspace = workspace; transport = workspace.store.transport
        identity = workspace.attachmentIdentity(session)
        prepare()
    }
    private func prepare() {
        let host = session.host; let tmux = session.tmuxID; let transport = transport; let flag = cancellation
        Task {
            do {
                let context = try await Task.detached { () -> (String, TmuxTarget?) in
                    let pane = try tmux.map { try TmuxService(transport: transport, host: host).target(session: $0) }
                    let temporary = try AttachmentUploader(transport: transport).temporaryDirectory(host: host, cancellation: flag)
                    return (temporary, pane)
                }.value
                guard !disposed else { return }
                target = context.1
                directory = context.0
                preparing = false; status = L10n.text("目标：\(session.displayName)\(target.map { L10n.text(" · 窗格 ") + $0.paneID } ?? "")")
                upload()
            } catch { guard !disposed else { return }; preparing = false; failure = error.localizedDescription }
        }
    }
    func upload() {
        guard !running, !preparing, !disposed, session.connected, session.connectionID == identity.connectionID else { return }
        running = true; failure = nil; result = nil; cancellation = CancellationFlag()
        let flag = cancellation; let host = session.host; let files = payload.files; let destination = directory; let transport = transport
        Task {
            do {
                let uploaded = try await Task.detached {
                    try AttachmentUploader(transport: transport).upload(files, host: host, directory: destination, cancellation: flag) { [weak owner = self] message, value in
                        DispatchQueue.main.async { guard owner?.disposed == false else { return }; owner?.status = message; owner?.progress = value }
                    }
                }.value
                guard !disposed else { return }
                running = false; result = uploaded; status = L10n.text("目标机器的 \(uploaded.fileCount) 个文件回读校验通过")
                if let workspace, workspace.attachmentIdentity(session) == identity, workspace.selectedTerminalID == session.id, workspace.page == .terminal {
                    await insert(requireOriginalFocus: true)
                } else { status += L10n.text("；会话或焦点已变化，请回原终端后点击插入。") }
            } catch { guard !disposed else { return }; running = false; failure = error.localizedDescription }
        }
    }
    func insert(requireOriginalFocus: Bool = false) async {
        guard let result, let workspace, !disposed, !inserting else { return }
        guard workspace.selectedTerminalID == session.id, workspace.page == .terminal, session.connected,
              session.connectionID == identity.connectionID,
              (!requireOriginalFocus || workspace.attachmentIdentity(session) == identity) else {
            failure = L10n.text("接收终端或连接已变化。请回到原连接，确认输入位置后重试；未插入路径。"); return
        }
        inserting = true; defer { inserting = false }
        do {
            let transport = transport; let host = session.host
            try await Task.detached {
                let client = try transport.files(host); defer { client.close() }
                for path in result.paths {
                    let attributes = try client.stat(path)
                    if attributes.isDirectory { _ = try client.list(path) }
                    else { _ = try client.preview(path, offset: 0, limit: 1) }
                }
            }.value
            guard !disposed, workspace.selectedTerminalID == session.id, workspace.page == .terminal,
                  session.connected, session.connectionID == identity.connectionID,
                  (!requireOriginalFocus || workspace.attachmentIdentity(session) == identity) else {
                throw WorkbenchError.message(L10n.text("插入前目标发生变化，附件未发送。"))
            }
            let text = try AttachmentReference.text(paths: result.paths)
            if let tmuxID = session.tmuxID, let target {
                let service = TmuxService(transport: transport, host: session.host)
                try await Task.detached { try service.paste(text, session: tmuxID, expected: target) }.value
            } else {
                session.terminal.sendAttachmentReference(text)
            }
            inserted = true; status = L10n.text("已插入目标机器路径引用，未自动回车。Agent 读取/图片识别状态以 Agent 提示为准。"); failure = nil
        } catch { failure = error.localizedDescription }
    }
    func deleteUploaded() async {
        guard let result, !running, !inserting else { return }
        let transport = transport; let host = session.host
        do {
            try await Task.detached {
                let client = try transport.files(host); defer { client.close() }
                guard (result.directory as NSString).lastPathComponent.hasPrefix(".farport-attachments-") else { throw WorkbenchError.message(L10n.text("拒绝清理非附件目录")) }
                try client.removeRecursively(result.directory)
            }.value
            self.result = nil; status = L10n.text("附件已清理，之前插入的路径将不再可读。")
        } catch { failure = error.localizedDescription }
    }
    func cancel() { cancellation.cancel() }
    func retry() {
        guard !busy, !disposed else { return }
        failure = nil; preparing = true; cancellation = CancellationFlag(); prepare()
    }
    var busy: Bool { preparing || running || inserting }
    func dispose() {
        disposed = true; cancellation.cancel()
        if let directory = payload.temporaryDirectory { try? FileManager.default.removeItem(at: directory) }
    }
}

struct TerminalAttachmentBanner: View {
    @ObservedObject var draft: TerminalAttachmentDraft
    let dismiss: () -> Void
    @ViewState private var showDetails = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: draft.inserted ? "checkmark.circle.fill" : (draft.failure == nil ? "paperclip" : "exclamationmark.triangle"))
                .foregroundStyle(draft.failure == nil ? Color.teal : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("\(draft.payload.files.count) 个附件 → \(draft.session.displayName)")).font(.system(size: 11, weight: .semibold))
                Text(draft.failure ?? draft.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            if draft.running { ProgressView(value: draft.progress).frame(width: 90) }
            else if draft.preparing || draft.inserting { ProgressView().controlSize(.small) }
            Spacer(minLength: 4)
            if draft.preparing || draft.running { Button(L10n.text("取消")) { draft.cancel() } }
            if !draft.busy, draft.result != nil, !draft.inserted { Button(L10n.text("插入原终端")) { Task { await draft.insert() } } }
            if !draft.busy, draft.result == nil, draft.failure != nil { Button(L10n.text("重试")) { draft.retry() } }
            Button(L10n.text("详情")) { showDetails.toggle() }.popover(isPresented: $showDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("附件目标 · \(draft.session.displayName)")).font(.headline)
                    Text(draft.session.subtitle).font(.caption).textSelection(.enabled)
                    Text(draft.result?.paths.joined(separator: "\n") ?? draft.directory).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    Text(L10n.text("已按当前连接机器上传到私有临时目录，不自动回车。若终端内又 SSH 到其他主机、进入容器或切换用户，此路径不一定可读，请改用实际目标连接。临时文件可能被系统清理，需要长期保留时请移动到工作目录。")).font(.caption).foregroundStyle(.secondary)
                    if draft.result != nil {
                        Button(L10n.text("清理本批附件…"), role: .destructive) {
                            if confirm(L10n.text("清理本批附件？"), L10n.text("Agent 之后将无法读取这些路径，源文件不受影响。")) { Task { await draft.deleteUploaded() } }
                        }.disabled(draft.busy)
                    }
                }.padding(18).frame(width: 400)
            }
            Button { draft.dispose(); dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 28).contentShape(Rectangle()) }.disabled(draft.inserting).help(L10n.text("关闭附件状态"))
        }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 10).background(.teal.opacity(0.06))
    }
}
