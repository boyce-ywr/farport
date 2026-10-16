import AppKit
import SwiftUI
import WorkbenchCore

@MainActor
final class TerminalClipboardState: ObservableObject {
    @Published private(set) var message = ""
    @Published private(set) var failed = false
    @Published private(set) var remoteAllowed: Bool?
    @Published private(set) var pendingRemoteText: String?
    @Published var hasSelection = false
    private var prompting = false
    private var notice: Task<Void, Never>?
    deinit { notice?.cancel() }
    func report(_ message: String, failed: Bool = false) {
        notice?.cancel(); self.message = message; self.failed = failed
        notice = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(failed ? 7 : 2)) } catch { return }
            self?.message = ""
        }
    }
    @discardableResult func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), pasteboard.string(forType: .string) == text else {
            report(L10n.text("写入 Mac 剪贴板失败，请重试。"), failed: true); return false
        }
        report(L10n.text("已复制到 Mac 剪贴板")); return true
    }
    func receive(_ data: Data, interactive: Bool, confirm: () -> Bool) {
        guard data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            report(L10n.text("未复制：终端内容为空、编码无效或超过 1 MiB。"), failed: true); return
        }
        guard interactive else {
            pendingRemoteText = text
            report(L10n.text("后台终端的复制请求已暂存，未改动剪贴板。"), failed: true); return
        }
        pendingRemoteText = text
        if remoteAllowed == nil {
            guard !prompting else { return }
            prompting = true
            remoteAllowed = confirm()
            prompting = false
        }
        if remoteAllowed == true {
            if let pendingRemoteText, write(pendingRemoteText) { self.pendingRemoteText = nil }
        } else { report(L10n.text("终端复制已阻止；可在剪贴板菜单中允许。"), failed: true) }
    }
    func allowRemoteCopy() {
        remoteAllowed = true
        if let pendingRemoteText, write(pendingRemoteText) { self.pendingRemoteText = nil }
    }
    func denyRemoteCopy() {
        remoteAllowed = false; pendingRemoteText = nil
        report(L10n.text("已禁止此终端写入剪贴板；本地选中复制不受影响。"))
    }
    func resetPermission() { remoteAllowed = nil; pendingRemoteText = nil }
}

struct TerminalClipboardControls: View {
    let terminal: SafeTerminalView
    @ObservedObject var state: TerminalClipboardState
    var body: some View {
        HStack(spacing: 4) {
            Button { terminal.onContextFocus?(); terminal.copy(terminal) } label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 30) }
                .help(L10n.text("复制选中文本 · ⌘C；按住 Shift 拖选可绕过 tmux/终端程序。"))
                .accessibilityLabel(L10n.text("复制"))
            Button { terminal.onContextFocus?(); terminal.window?.makeFirstResponder(terminal); terminal.paste(terminal) } label: { Image(systemName: "doc.on.clipboard").frame(width: 24, height: 30) }
                .help(L10n.text("粘贴 · ⌘V")).accessibilityLabel(L10n.text("粘贴"))
            Menu {
                Button(L10n.text("复制")) { terminal.copy(terminal) }.disabled(!state.hasSelection)
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
            Label(state.message, systemImage: state.failed ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 11)).foregroundStyle(state.failed ? Color.orange : .primary)
                .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 320, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
        }
    }
}
