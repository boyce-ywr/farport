import AppKit
import SwiftUI
import CryptoKit
import WorkbenchCore

extension AppStore {
    private func draftURL(host: HostProfile?, path: String) -> URL {
        let identity = [host?.id.uuidString ?? "local", host?.connectionKey ?? "", path].joined(separator: "\0")
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return paths.root.appendingPathComponent("editor-drafts").appendingPathComponent(name + ".json")
    }
    func loadEditorDraft(host: HostProfile?, path: String) throws -> EditorDraft? {
        let url = draftURL(host: host, path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let draft = try paths.load(EditorDraft.self, from: url)
        guard draft.isValid, draft.hostID == host?.id, draft.connectionKey == host?.connectionKey, draft.path == path else {
            throw WorkbenchError.message(L10n.text("草稿记录无效或来源不匹配，原文件已保留。"))
        }
        return draft
    }
    func saveEditorDraft(host: HostProfile?, path: String, original: Data, edited: Data, replacing identifier: UUID?) throws -> EditorDraft {
        if let existing = try loadEditorDraft(host: host, path: path), existing.id != identifier {
            throw WorkbenchError.message(L10n.text("已有另一份恢复草稿，未覆盖它。请保留当前编辑内容并先处理旧草稿。"))
        }
        let draft = EditorDraft(hostID: host?.id, connectionKey: host?.connectionKey, path: path, original: original, edited: edited)
        guard draft.isValid else { throw WorkbenchError.message(L10n.text("草稿必须是 512 KiB 以内的 UTF-8 文本。")) }
        let url = draftURL(host: host, path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try paths.save(draft, to: url)
        return draft
    }
    func removeEditorDraft(host: HostProfile?, path: String, identifier: UUID?) throws {
        guard let identifier, let existing = try loadEditorDraft(host: host, path: path), existing.id == identifier else { return }
        try FileManager.default.removeItem(at: draftURL(host: host, path: path))
    }
}

struct TextChangesView: View {
    let original: String
    let edited: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let preview = TextChangePreview(original: original, edited: edited)
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L10n.text("保存前差异预览")).font(.title2); Spacer(); Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(L10n.text("与上次读取或保存的版本比较；保存时仍会复核文件是否被外部修改。"))
                .font(.caption).foregroundStyle(.secondary)
            if preview.isEmpty { Text(L10n.text("没有内容变化")) }
            else {
                HStack { Text(L10n.text("起始行")); Text("\(preview.firstLine)"); Spacer(); Text("−\(preview.removedCount) / +\(preview.addedCount)").monospacedDigit() }
                HSplitView {
                    column(L10n.text("原内容"), text: preview.removed, color: .red)
                    column(L10n.text("新内容"), text: preview.added, color: .green)
                }
                if preview.truncated { Text(L10n.text("变更区域较大，每侧仅显示前 200 行；完整内容仍保留在编辑器。")) .font(.caption).foregroundStyle(.orange) }
            }
        }.padding(22).frame(width: 800, height: 470)
    }
    private func column(_ title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline).foregroundStyle(color)
            ScrollView([.horizontal, .vertical]) { Text(verbatim: text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(8) }
                .background(color.opacity(0.05))
        }.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }
}
