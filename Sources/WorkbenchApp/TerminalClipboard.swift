import AppKit
import SwiftUI
import WorkbenchCore
import CryptoKit

@MainActor
final class TerminalClipboardState: ObservableObject {
    @Published private(set) var message = ""
    @Published private(set) var failed = false
    @Published private(set) var informational = false
    @Published private(set) var remoteAllowed: Bool?
    @Published private(set) var pendingRemoteText: String?
    @Published var hasSelection = false
    var writePolicy: () -> TerminalClipboardWritePolicy = { .ask }
    var readAllowed: () -> Bool = { false }
    private var lastPolicy: TerminalClipboardWritePolicy = .ask
    private var lastRead: TimeInterval = -.infinity
    private var prompting = false
    private var notice: Task<Void, Never>?
    private var copyWait: Task<Void, Never>?
    private var copyRequest = UUID()
    private var selectionCancellation: CancellationFlag?
    private var interaction: UInt64 = 0
    private var remoteProof: (changeCount: Int, digest: SHA256.Digest, date: Date, interaction: UInt64)?
    private var reportedCopy = false
    deinit { notice?.cancel(); copyWait?.cancel(); selectionCancellation?.cancel() }
    func report(_ message: String, failed: Bool = false, informational: Bool = false) {
        selectionCancellation?.cancel(); selectionCancellation = nil
        copyWait?.cancel(); copyWait = nil; copyRequest = UUID()
        notice?.cancel(); self.message = message; self.failed = failed; self.informational = informational; reportedCopy = false
        notice = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(failed ? 7 : 2)) } catch { return }
            self?.message = ""
        }
    }
    @discardableResult func write(_ text: String, remote: Bool = false) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), pasteboard.string(forType: .string) == text else {
            report(L10n.text("写入 Mac 剪贴板失败，请重试。"), failed: true); return false
        }
        remoteProof = remote ? (pasteboard.changeCount, SHA256.hash(data: Data(text.utf8)), Date(), interaction) : nil
        report(L10n.text("已复制到 Mac 剪贴板")); reportedCopy = true; return true
    }
    func noteUserInteraction() {
        if selectionCancellation != nil { message = ""; selectionCancellation?.cancel(); selectionCancellation = nil }
        interaction &+= 1; remoteProof = nil; copyWait?.cancel(); copyWait = nil; copyRequest = UUID()
        if reportedCopy { notice?.cancel(); message = ""; reportedCopy = false }
    }
    func copyTmuxSelection(read: @escaping (CancellationFlag) async throws -> Data?, isStillInteractive: @escaping () -> Bool) {
        guard isStillInteractive() else { return }
        if confirmedRecentRemoteCopy() { report(L10n.text("已复制到 Mac 剪贴板")); reportedCopy = true; return }
        report(L10n.text("正在复制 tmux 选区…"), informational: true)
        let request = copyRequest
        let flag = CancellationFlag(); selectionCancellation = flag
        let changeCount = NSPasteboard.general.changeCount
        notice?.cancel()
        notice = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, copyRequest == request else { return }
            report(L10n.text("读取 tmux 选区超时；可用 Shift 拖选后 ⌘C 直接复制。"), failed: true)
        }
        copyWait = Task { [weak self] in
            let focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: NSApp.keyWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteUserInteraction() }
            }
            let applicationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteUserInteraction() }
            }
            defer { NotificationCenter.default.removeObserver(focusObserver); NotificationCenter.default.removeObserver(applicationObserver) }
            do {
                let data = try await read(flag)
                guard let self, copyRequest == request, !flag.isCancelled else { return }
                guard isStillInteractive() else { noteUserInteraction(); return }
                guard NSPasteboard.general.changeCount == changeCount else {
                    report(L10n.text("剪贴板已被其他操作更新，未覆盖；请重新复制。"), informational: true); return
                }
                guard let data else {
                    if confirmedRecentRemoteCopy() { report(L10n.text("已复制到 Mac 剪贴板")); reportedCopy = true }
                    else { report(L10n.text("tmux 当前没有可读取的选区；请保持选区后按 ⌘C，或用 Shift 拖选直接复制。"), informational: true) }
                    return
                }
                guard data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                    report(L10n.text("tmux 选区为空、编码无效或超过 1 MiB，未写入剪贴板。"), failed: true); return
                }
                write(text)
            } catch {
                guard let self, copyRequest == request, !flag.isCancelled else { return }
                guard isStillInteractive() else { noteUserInteraction(); return }
                report(L10n.text("无法读取当前 tmux 选区；请重试或用 Shift 拖选后 ⌘C 复制。"), failed: true)
            }
        }
    }
    func noLocalSelection(remoteContext: Bool) {
        if confirmedRecentRemoteCopy() { report(L10n.text("已复制到 Mac 剪贴板")); reportedCopy = true; return }
        guard remoteContext else { report(L10n.text("没有本地选区；请按住 Shift 拖选，再按 ⌘C。"), failed: true); return }
        if pendingRemoteText != nil && remoteAllowed == false { report(L10n.text("终端复制已阻止；可在剪贴板菜单中允许。"), failed: true); return }
        copyWait?.cancel(); notice?.cancel(); message = ""; failed = false; informational = true
        let request = UUID(); copyRequest = request
        copyWait = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard let self, copyRequest == request else { return }
            if confirmedRecentRemoteCopy() { report(L10n.text("已复制到 Mac 剪贴板")); reportedCopy = true }
            else { report(L10n.text("未收到新的终端剪贴板同步；可按 Shift 拖选后 ⌘C 直接复制。"), informational: true) }
        }
    }
    private func confirmedRecentRemoteCopy() -> Bool {
        guard let proof = remoteProof, proof.interaction == interaction,
              (0...2).contains(Date().timeIntervalSince(proof.date)), NSPasteboard.general.changeCount == proof.changeCount,
              let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 1024 * 1024 else { return false }
        return SHA256.hash(data: Data(text.utf8)) == proof.digest
    }
    private func synchronizePolicy() -> TerminalClipboardWritePolicy {
        let policy = writePolicy()
        if policy != lastPolicy { remoteAllowed = nil; lastPolicy = policy }
        return policy
    }
    func read(interactive: Bool) -> Data? {
        guard interactive, readAllowed(), ProcessInfo.processInfo.systemUptime - lastRead >= 0.1,
              let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 1024 * 1024 else { return nil }
        lastRead = ProcessInfo.processInfo.systemUptime
        return Data(text.utf8)
    }
    func receive(_ data: Data, interactive: Bool, isStillInteractive: () -> Bool = { true }, confirm: () -> Bool) {
        remoteProof = nil
        let policy = synchronizePolicy()
        guard policy != .deny else { pendingRemoteText = nil; report(L10n.text("已按设置禁止终端写入剪贴板。"), informational: true); return }
        guard data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingRemoteText = nil
            report(L10n.text("未复制：终端内容为空、仅含空白、编码无效或超过 1 MiB。"), failed: true); return
        }
        guard interactive else {
            pendingRemoteText = text
            report(L10n.text("后台终端的复制请求已暂存，未改动剪贴板。"), failed: true); return
        }
        pendingRemoteText = text
        if remoteAllowed == nil, policy == .ask {
            guard !prompting else { return }
            prompting = true
            remoteAllowed = confirm()
            prompting = false
        }
        let currentPolicy = synchronizePolicy()
        guard isStillInteractive(), currentPolicy != .deny else { return }
        if remoteAllowed == true || (currentPolicy == .allow && remoteAllowed != false) {
            if let pendingRemoteText, write(pendingRemoteText, remote: true) { self.pendingRemoteText = nil }
        } else { report(L10n.text("终端复制已阻止；可在剪贴板菜单中允许。"), failed: true) }
    }
    func allowRemoteCopy() {
        guard synchronizePolicy() != .deny else { report(L10n.text("已按设置禁止终端写入剪贴板。"), informational: true); return }
        remoteAllowed = true
        if let pendingRemoteText, write(pendingRemoteText, remote: true) { self.pendingRemoteText = nil }
    }
    func denyRemoteCopy() {
        _ = synchronizePolicy()
        remoteAllowed = false; pendingRemoteText = nil
        report(L10n.text("已禁止此终端写入剪贴板；本地选中复制不受影响。"))
    }
    func resetPermission() { selectionCancellation?.cancel(); selectionCancellation = nil; remoteAllowed = nil; pendingRemoteText = nil; remoteProof = nil; lastRead = -.infinity; copyWait?.cancel(); copyWait = nil; copyRequest = UUID(); notice?.cancel(); message = ""; failed = false; informational = false; reportedCopy = false }
}

struct TerminalClipboardControls: View {
    let terminal: SafeTerminalView
    @ObservedObject var state: TerminalClipboardState
    var body: some View {
        HStack(spacing: 4) {
            Button { terminal.onContextFocus?(); terminal.window?.makeFirstResponder(terminal); terminal.copy(terminal) } label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 30) }
                .help(L10n.text("复制选中文本 · ⌘C；按住 Shift 拖选可绕过 tmux/终端程序。"))
                .accessibilityLabel(L10n.text("复制"))
            Button { terminal.onContextFocus?(); terminal.window?.makeFirstResponder(terminal); terminal.paste(terminal) } label: { Image(systemName: "doc.on.clipboard").frame(width: 24, height: 30) }
                .help(L10n.text("粘贴 · ⌘V")).accessibilityLabel(L10n.text("粘贴"))
            Menu {
                Button(L10n.text("复制")) { terminal.window?.makeFirstResponder(terminal); terminal.copy(terminal) }.disabled(!state.hasSelection && terminal.copyRemoteSelection == nil)
                Button(L10n.text("复制所选命令全文")) { terminal.copySemanticCommand(output: false) }.disabled(!state.hasSelection || !terminal.semanticCommandCopyAllowed)
                Button(L10n.text("复制所选命令的输出")) { terminal.copySemanticCommand(output: true) }.disabled(!state.hasSelection || !terminal.semanticCommandCopyAllowed)
                Divider()
                Button(state.pendingRemoteText == nil ? L10n.text("允许此终端写入剪贴板") : L10n.text("允许并复制刚才的内容")) { state.allowRemoteCopy() }
                Button(L10n.text("禁止此终端写入剪贴板")) { state.denyRemoteCopy() }
                Text(L10n.text("Shift 拖选后 ⌘C：直接复制到 Mac，不依赖远端程序。"))
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 12)
        }
    }
}

struct TerminalClipboardFeedback: View {
    @ObservedObject var state: TerminalClipboardState
    var body: some View {
        if !state.message.isEmpty {
            Label(state.message, systemImage: state.failed ? "exclamationmark.circle" : (state.informational ? "info.circle" : "checkmark.circle"))
                .font(.system(size: 11)).foregroundStyle(state.failed ? Color.orange : .primary)
                .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 320, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
        }
    }
}
