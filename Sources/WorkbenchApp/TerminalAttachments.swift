import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WorkbenchCore
import OpenSSHBackend

struct TerminalAttachmentPayload {
    let files: [URL]
    let temporaryDirectory: URL?
}

enum TerminalAttachmentIntake {
    enum Source: Sendable { case files([URL]); case png(Data); case raster(Data) }
    @MainActor static func capture(_ pasteboard: NSPasteboard) throws -> Source? {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            return .files(files)
        }
        if let data = pasteboard.data(forType: .png) { try validate(data); return .png(data) }
        if let data = pasteboard.data(forType: .tiff) { try validate(data); return .raster(data) }
        return nil
    }
    private static func validate(_ data: Data) throws {
        guard data.count <= 128 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, Int64(width) * Int64(height) <= 64_000_000 else {
            throw WorkbenchError.message(L10n.text("剪贴板图像无效或过大，请通过文件上传。"))
        }
    }
    static func materialize(_ source: Source, stagingRoot: URL) throws -> TerminalAttachmentPayload {
        switch source {
        case .files(let files): return TerminalAttachmentPayload(files: files, temporaryDirectory: nil)
        case .png(let data):
            let directory = stagingRoot.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("clipboard-" + UUID().uuidString.lowercased() + ".png")
            do {
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
            return TerminalAttachmentPayload(files: [file], temporaryDirectory: directory)
        case .raster(let data):
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw WorkbenchError.message(L10n.text("剪贴板图像无效或过大，请通过文件上传。"))
            }
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
}

@MainActor
final class TerminalAttachmentDraft: ObservableObject, Identifiable {
    let id = UUID()
    let session: TerminalSession
    let payload: TerminalAttachmentPayload
    let identity: AttachmentDeliveryIdentity
    let automaticallyInsert: Bool
    private weak var workspace: Workspace?
    @Published var directory = ""
    @Published var preparing = true
    @Published var running = false
    @Published var inserting = false
    @Published var settlingFocus = false
    @Published var progress: Double = 0
    @Published var status = L10n.text("正在确认目标…")
    @Published var failure: String?
    @Published var result: UploadedAttachments?
    @Published var inserted = false
    @Published var target: TmuxTarget?
    @Published var containerSelection: DockerAttachmentSelection?
    @Published var showContainerPicker = false
    @Published private(set) var dockerBinding: DockerAttachmentBinding?
    private var dockerResult: DockerUploadedAttachments?
    private var cancellation = CancellationFlag()
    private var disposed = false
    private let transport: SSHTransport
    var targetDescription: String { dockerBinding.map { session.displayName + " → Docker · " + $0.container.displayName + " · " + $0.user } ?? session.displayName }
    init(session: TerminalSession, payload: TerminalAttachmentPayload, workspace: Workspace) {
        self.session = session; self.payload = payload; self.workspace = workspace; transport = workspace.store.transport
        identity = workspace.attachmentIdentity(session)
        automaticallyInsert = workspace.store.automaticallyInsertAttachments(for: session.host)
        prepare()
    }
    private func prepare() {
        let host = session.host; let tmux = session.tmuxID; let transport = transport; let flag = cancellation
        let remembered = session.dockerAttachmentBinding
        Task {
            do {
                let context = try await Task.detached { () -> (String, TmuxTarget?, DockerAttachmentSelection?, DockerAttachmentBinding?) in
                    if let tmux {
                        let service = TmuxService(transport: transport, host: host)
                        if try service.attachmentTarget(session: tmux).command == "docker" {
                            let terminal = try service.dockerTerminal(session: tmux, cancellation: flag)
                            if let remembered, remembered.terminal == terminal, (try? remembered.daemon.validate(remembered, cancellation: flag)) != nil {
                                return ("", terminal.target, nil, remembered)
                            }
                            let selection = try DockerAttachmentDaemon.discover(terminal: terminal, transport: transport, cancellation: flag)
                            // 已从原窗格 docker 命令核对出容器时直接使用，不再要求手动选择。
                            if selection.containers.contains(where: { $0.id == selection.detectedContainerID }) {
                                return ("", terminal.target, nil, try selection.daemon.confirm(selection.detectedContainerID, terminal: terminal, cancellation: flag))
                            }
                            return ("", terminal.target, selection, nil)
                        }
                    }
                    let pane = try tmux.map { try TmuxService(transport: transport, host: host).target(session: $0) }
                    let temporary = try AttachmentUploader(transport: transport).temporaryDirectory(host: host, cancellation: flag)
                    return (temporary, pane, nil, nil)
                }.value
                guard !disposed, !flag.isCancelled else { preparing = false; return }
                target = context.1
                directory = context.0
                dockerBinding = context.3
                if let binding = context.3 { session.dockerAttachmentBinding = binding }
                if let selection = context.2 {
                    session.dockerAttachmentBinding = nil
                    containerSelection = selection; preparing = false
                    status = L10n.text("请选择并确认原窗格的目标容器，确认前不会复制附件。")
                    showContainerPicker = true; return
                }
                preparing = false; status = L10n.text("目标：\(session.displayName)\(target.map { L10n.text(" · 窗格 ") + $0.paneID } ?? "")")
                upload()
            } catch { guard !disposed else { return }; preparing = false; failure = error.localizedDescription }
        }
    }
    func chooseContainer(_ identifier: String) async {
        guard let selection = containerSelection, !preparing, !disposed, let tmux = session.tmuxID else { return }
        preparing = true; failure = nil
        let transport = transport; let flag = cancellation
        do {
            let binding = try await Task.detached {
                let current = try TmuxService(transport: transport, host: selection.terminal.host).dockerTerminal(session: tmux, cancellation: flag)
                guard current == selection.terminal else { throw WorkbenchError.message(L10n.text("Docker 进程或原 tmux 窗格已变化，请重新确认容器。")) }
                return try selection.daemon.confirm(identifier, terminal: current, cancellation: flag)
            }.value
            guard !disposed, !flag.isCancelled, session.connectionID == identity.connectionID,
                  workspace?.selectedTerminalID == session.id, session.inputGeneration == identity.inputGeneration else {
                throw WorkbenchError.message(L10n.text("插入前目标发生变化，附件未发送。"))
            }
            dockerBinding = binding; session.dockerAttachmentBinding = binding
            containerSelection = nil; showContainerPicker = false; preparing = false
            for _ in 0..<20 {
                guard !disposed, !flag.isCancelled, NSApp.isActive, workspace?.selectedTerminalID == session.id,
                      workspace?.page == .terminal, session.inputGeneration == identity.inputGeneration,
                      let window = session.terminal.window else { break }
                if window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil {
                    if !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) { window.makeFirstResponder(session.terminal) }
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            upload()
        } catch { preparing = false; failure = error.localizedDescription }
    }
    func upload() {
        guard !running, !preparing, !disposed, session.connected, session.connectionID == identity.connectionID else { return }
        running = true; failure = nil; result = nil; cancellation = CancellationFlag()
        let flag = cancellation; let host = session.host; let files = payload.files; let destination = directory; let transport = transport
        let binding = dockerBinding; let tmux = session.tmuxID
        Task {
            do {
                let outcome = try await Task.detached { () -> (UploadedAttachments, DockerUploadedAttachments?) in
                    let progress: (String, Double) -> Void = { [weak owner = self] message, value in
                        DispatchQueue.main.async { guard owner?.disposed == false, owner?.running == true, !flag.isCancelled else { return }; owner?.status = message; owner?.progress = value }
                    }
                    if let binding, let tmux {
                        guard try TmuxService(transport: transport, host: binding.terminal.host).dockerTerminal(session: tmux, cancellation: flag) == binding.terminal else { throw WorkbenchError.message(L10n.text("Docker 进程或原 tmux 窗格已变化，请重新确认容器。")) }
                        let uploaded = try DockerAttachmentUploader(binding: binding).upload(files, transport: transport, cancellation: flag, progress: progress)
                        return (uploaded.uploaded, uploaded)
                    }
                    return (try AttachmentUploader(transport: transport).upload(files, host: host, directory: destination, cancellation: flag, progress: progress), nil)
                }.value
                guard !disposed else { return }
                let uploaded = outcome.0; dockerResult = outcome.1
                directory = uploaded.directory
                running = false; result = uploaded; status = L10n.text("目标机器的 \(uploaded.fileCount) 个文件回读校验通过")
                if !automaticallyInsert { status += L10n.text("；已按设置等待手动插入。") }
                else if await waitForAutomaticTarget() { await insert(requireOriginalFocus: true) }
            } catch { guard !disposed else { return }; running = false; failure = error.localizedDescription }
        }
    }
    private func waitForAutomaticTarget() async -> Bool {
        guard let workspace else { return false }
        settlingFocus = true; defer { settlingFocus = false }
        var stable = 0
        for _ in 0..<120 {
            guard !disposed, !cancellation.isCancelled, !inserted else { return false }
            if let reason = workspace.automaticInsertionBlocker(self) { status = L10n.text("附件已上传：") + reason; return false }
            workspace.restoreTransientAttachmentFocus(self)
            if workspace.canAutomaticallyInsert(self) { stable += 1; if stable >= 2 { return true } }
            else { stable = 0; status = L10n.text("附件已上传，正在等待原终端焦点稳定…") }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        status = L10n.text("附件已上传，但原终端尚未恢复输入焦点；请确认后手动插入。")
        return false
    }
    func insert(requireOriginalFocus: Bool = false) async {
        guard let result, let workspace, !disposed, !inserting, !inserted else { return }
        if !requireOriginalFocus, session.connectionID != identity.connectionID {
            guard session.connected, session.connectionConfigurationValid(), confirm(L10n.text("连接已重建，确认插入已上传的附件？"), L10n.text("只会向当前选中的原主机终端发送路径；仍会重新检查文件和 tmux 窗格，不会自动回车。")) else { return }
        }
        let expectedConnection = requireOriginalFocus ? identity.connectionID : session.connectionID
        guard workspace.selectedTerminalID == session.id, workspace.page == .terminal, session.connected,
              session.connectionID == expectedConnection,
              (!requireOriginalFocus || workspace.canAutomaticallyInsert(self)) else {
            failure = L10n.text("接收终端或连接已变化。请回到原连接，确认输入位置后重试；未插入路径。"); return
        }
        inserting = true; defer { inserting = false }
        do {
            let transport = transport; let host = session.host
            let binding = dockerBinding; let dockerResult = dockerResult; let flag = cancellation
            try await Task.detached {
                if let binding, let dockerResult {
                    try DockerAttachmentUploader(binding: binding).verify(dockerResult, cancellation: flag); return
                }
                let client = try transport.files(host); defer { client.close() }
                for path in result.paths {
                    let attributes = try client.stat(path)
                    if attributes.isDirectory { _ = try client.list(path) }
                    else { _ = try client.preview(path, offset: 0, limit: 1) }
                }
            }.value
            if requireOriginalFocus, !(await waitForAutomaticTarget()) { return }
            guard !disposed, workspace.selectedTerminalID == session.id, workspace.page == .terminal,
                  session.connected, session.connectionID == expectedConnection,
                  (!requireOriginalFocus || workspace.canAutomaticallyInsert(self)) else {
                throw WorkbenchError.message(L10n.text("插入前目标发生变化，附件未发送。"))
            }
            let text = try AttachmentReference.text(paths: result.paths)
            if let binding, let tmuxID = session.tmuxID {
                let service = TmuxService(transport: transport, host: binding.terminal.host)
                try await Task.detached { try service.pasteDocker(text, session: tmuxID, expected: binding.terminal) }.value
            } else if let tmuxID = session.tmuxID, let target {
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
        let transport = transport; let host = session.host; let binding = dockerBinding
        do {
            try await Task.detached {
                if let binding { try DockerAttachmentUploader(binding: binding).cleanup(result.directory, cancellation: CancellationFlag()); return }
                let client = try transport.files(host); defer { client.close() }
                guard (result.directory as NSString).lastPathComponent.hasPrefix(".farport-attachments-") else { throw WorkbenchError.message(L10n.text("拒绝清理非附件目录")) }
                try client.removeRecursively(result.directory)
            }.value
            self.result = nil; status = L10n.text("附件已清理，之前插入的路径将不再可读。")
        } catch { failure = error.localizedDescription }
    }
    func cancel() {
        cancellation.cancel()
        if containerSelection != nil { failure = L10n.text("已取消容器选择，未发送附件。") }
        containerSelection = nil; showContainerPicker = false
    }
    func retry() {
        guard !busy, !disposed else { return }
        failure = nil; containerSelection = nil; dockerBinding = nil; dockerResult = nil
        preparing = true; cancellation = CancellationFlag(); prepare()
    }
    var busy: Bool { preparing || running || inserting || settlingFocus || containerSelection != nil }
    func dispose() {
        disposed = true; cancellation.cancel()
        showContainerPicker = false; containerSelection = nil
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
                Text(L10n.text("\(draft.payload.files.count) 个附件 → \(draft.targetDescription)")).font(.system(size: 11, weight: .semibold))
                Text(draft.failure ?? draft.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            if draft.running { ProgressView(value: draft.progress).frame(width: 90) }
            else if draft.preparing || draft.inserting { ProgressView().controlSize(.small) }
            Spacer(minLength: 4)
            if draft.containerSelection != nil { Button(L10n.text("选择目标容器…")) { draft.showContainerPicker = true } }
            if draft.preparing || draft.running { Button(L10n.text("取消")) { draft.cancel() } }
            if !draft.busy, draft.result != nil, !draft.inserted { Button(L10n.text("插入原终端")) { Task { await draft.insert() } } }
            if !draft.busy, draft.result == nil, draft.failure != nil { Button(L10n.text("重试")) { draft.retry() } }
            Button(L10n.text("详情")) { showDetails.toggle() }.popover(isPresented: $showDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("附件目标 · \(draft.targetDescription)")).font(.headline)
                    Text(draft.session.subtitle).font(.caption).textSelection(.enabled)
                    Text(draft.result?.paths.joined(separator: "\n") ?? draft.directory).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    Text(draft.dockerBinding == nil
                         ? L10n.text("已按当前连接机器上传到私有临时目录，不自动回车。若终端内又 SSH 到其他主机、进入容器或切换用户，此路径不一定可读，请改用实际目标连接。临时文件可能被系统清理，需要长期保留时请移动到工作目录。")
                         : L10n.text("附件位于已确认容器的私有目录，使用已核对用户读回验证。绑定仅在当前 Docker 进程与容器未变化时复用；容器内再 SSH 或切换用户不会自动穿透。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if draft.result != nil {
                        Button(L10n.text("清理本批附件…"), role: .destructive) {
                            if confirm(L10n.text("清理本批附件？"), L10n.text("Agent 之后将无法读取这些路径，源文件不受影响。")) { Task { await draft.deleteUploaded() } }
                        }.disabled(draft.busy)
                    }
                }.padding(18).frame(width: 400)
            }
            Button { draft.dispose(); dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 28).contentShape(Rectangle()) }.disabled(draft.inserting).help(L10n.text("关闭附件状态"))
        }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 10).background(.teal.opacity(0.06))
            .sheet(isPresented: $draft.showContainerPicker) {
                if let selection = draft.containerSelection { ContainerAttachmentPicker(draft: draft, selection: selection) }
            }
    }
}
