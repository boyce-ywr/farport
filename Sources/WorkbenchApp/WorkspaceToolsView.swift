import AppKit
import SwiftUI
import WorkbenchCore

struct WorkspaceToolsMenu: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: AppStore
    var body: some View {
        Menu {
            Button(L10n.text("常用命令…")) { workspace.showCommandSnippets = true }
            Button(L10n.text("打开远程 Mac 桌面…")) { workspace.screenSharingHost = workspace.toolsHost }.disabled(workspace.toolsHost == nil)
            Button(L10n.text("远端网页与服务模板…")) { workspace.webServiceHost = workspace.toolsHost }.disabled(workspace.toolsHost == nil)
            Menu(L10n.text("恢复工作区")) {
                Text(L10n.text("在空窗口恢复布局；不会重放命令。"))
                ForEach(store.workspaceTools.workspaces) { snapshot in
                    Button("\(snapshot.title) · \(snapshot.terminals.count) · \(snapshot.updated.formatted(date: .abbreviated, time: .shortened))") { workspace.restoreWorkspace(snapshot) }
                        .disabled(!workspace.sessions.isEmpty)
                }
                if store.workspaceTools.workspaces.isEmpty { Text(L10n.text("还没有保存的工作区")) }
            }
            Divider()
            Button(L10n.text("定位终端当前目录")) { workspace.openTerminalDirectory() }
                .disabled(workspace.selectedTerminal == nil)
            Toggle(L10n.text("文件区跟随终端目录"), isOn: $workspace.followTerminalDirectory)
            Text(L10n.text("需要可信 OSC 7 目录报告；不修改远端 Shell。"))
            Menu(L10n.text("目录收藏")) {
                Button(L10n.text("收藏当前文件目录")) { addBookmark() }.disabled(workspace.page != .files || workspace.currentFileBrowser?.path.hasPrefix("/") != true)
                ForEach(store.workspaceTools.bookmarks) { bookmark in
                    Menu("\(bookmarkName(bookmark)) · \(bookmark.path)") {
                        Button(L10n.text("打开")) { openBookmark(bookmark) }
                        Button(L10n.text("移除收藏"), role: .destructive) { store.workspaceTools.bookmarks.removeAll { $0.id == bookmark.id }; store.saveWorkspaceTools() }
                    }
                }
            }
        } label: { Image(systemName: "square.grid.2x2").frame(width: 26, height: 32) }
        .menuStyle(.borderlessButton).fixedSize().help(L10n.text("工作工具"))
        .interactionFrame("workspace.tools")
    }
    private func bookmarkName(_ bookmark: DirectoryBookmark) -> String {
        guard let identifier = bookmark.hostID else { return L10n.text("此 Mac") }
        return store.hosts.first { $0.id == identifier }?.name ?? L10n.text("主机已移除")
    }
    private func addBookmark() {
        guard let browser = workspace.currentFileBrowser, browser.path.hasPrefix("/") else { return }
        let bookmark = DirectoryBookmark(hostID: browser.host?.id, connectionKey: browser.host?.connectionKey, path: browser.path)
        guard !store.workspaceTools.bookmarks.contains(where: { $0.hostID == bookmark.hostID && $0.connectionKey == bookmark.connectionKey && $0.path == bookmark.path }) else { return }
        store.workspaceTools.bookmarks.append(bookmark); store.saveWorkspaceTools()
    }
    private func openBookmark(_ bookmark: DirectoryBookmark) {
        if let identifier = bookmark.hostID {
            guard store.hosts.contains(where: { $0.id == identifier && $0.connectionKey == bookmark.connectionKey }) else {
                store.errorMessage = L10n.text("主机已移除或连接配置已变化，请重新收藏目录。"); return
            }
            workspace.browseFiles(.host(identifier))
        } else { workspace.browseFiles(.local) }
        workspace.currentFileBrowser?.load(bookmark.path)
    }
}

struct CommandSnippetsView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft = CommandSnippet()
    @ViewState private var search = ""
    @ViewState private var message: String?
    @ViewState private var targetID: UUID?
    @ViewState private var targetConnection: UUID?
    init(workspace: Workspace, store: AppStore) {
        self.workspace = workspace; self.store = store
        _targetID = .init(initialValue: workspace.selectedTerminalID)
        _targetConnection = .init(initialValue: workspace.selectedTerminal?.connectionID)
    }
    private var target: TerminalSession? { workspace.sessions.first { $0.id == targetID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L10n.text("常用命令")).font(.title2); Spacer(); Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(L10n.text("只保存手动添加的单行命令，不记录终端输入。请勿保存密码。插入后需自行回车。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 18) {
                VStack {
                    TextField(L10n.text("搜索名称、标签或命令"), text: $search)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.workspaceTools.snippets.filter { search.isEmpty || ($0.name + $0.tags + $0.command).localizedCaseInsensitiveContains(search) }) { snippet in
                                Button { draft = snippet; message = nil } label: {
                                    VStack(alignment: .leading, spacing: 4) { Text(snippet.name).fontWeight(.medium); Text(snippet.command).font(.caption.monospaced()).lineLimit(2).foregroundStyle(.secondary) }
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(draft.id == snippet.id ? Color.teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Button(L10n.text("新建命令")) { draft = CommandSnippet(); message = nil }
                }.frame(width: 225)
                VStack(alignment: .leading, spacing: 12) {
                    TextField(L10n.text("名称"), text: $draft.name)
                    TextField(L10n.text("单行命令"), text: $draft.command).font(.system(.body, design: .monospaced))
                    TextField(L10n.text("标签"), text: $draft.tags)
                    Picker(L10n.text("适用主机"), selection: $draft.hostID) {
                        Text(L10n.text("全部主机与本机")).tag(nil as UUID?)
                        ForEach(store.hosts) { host in Text(host.name).tag(Optional(host.id)) }
                    }
                    Text(target.map { "\($0.displayName) · \($0.subtitle)" } ?? L10n.text("没有选中的终端；可以先保存命令。"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    HStack {
                        Button(L10n.text("删除"), role: .destructive) {
                            store.workspaceTools.snippets.removeAll { $0.id == draft.id }; store.saveWorkspaceTools(); draft = CommandSnippet()
                        }.disabled(!store.workspaceTools.snippets.contains { $0.id == draft.id })
                        Spacer()
                        Button(L10n.text("保存")) { save() }
                        Button(L10n.text("插入终端，不回车")) { insert() }.buttonStyle(.borderedProminent).disabled(target == nil)
                    }
                }
            }
        }.textFieldStyle(.roundedBorder).padding(22).frame(width: 780, height: 390)
    }
    private func save() {
        do {
            try draft.validate()
            if let index = store.workspaceTools.snippets.firstIndex(where: { $0.id == draft.id }) { store.workspaceTools.snippets[index] = draft }
            else { store.workspaceTools.snippets.append(draft) }
            message = store.flushWorkspaceTools() ? L10n.text("命令已保存到本机。") : store.errorMessage
        } catch { message = error.localizedDescription }
    }
    private func insert() {
        do {
            try draft.validate()
            try workspace.insertSnippet(draft, targetID: targetID, connectionID: targetConnection)
            dismiss()
            if let target { DispatchQueue.main.async { target.terminal.window?.makeFirstResponder(target.terminal) } }
        } catch { message = error.localizedDescription }
    }
}

extension Workspace {
    var toolsHost: HostProfile? {
        if page == .files { return fileHost }
        if page == .terminal, let selectedTerminal { return selectedTerminal.host }
        return host
    }
    func insertSnippet(_ snippet: CommandSnippet, targetID: UUID?, connectionID: UUID?) throws {
        try snippet.validate()
        guard let session = selectedTerminal, session.id == targetID, session.connected, session.connectionID == connectionID,
              snippet.hostID == nil || snippet.hostID == session.host?.id else {
            throw WorkbenchError.message(L10n.text("目标终端已变化、断开或不符合适用主机；请重新打开命令面板。"))
        }
        guard !session.terminal.getTerminal().isCurrentBufferAlternate else {
            throw WorkbenchError.message(L10n.text("请先退出全屏终端程序，确认位于 Shell 提示符后再插入命令。"))
        }
        session.terminal.onInputActivity?()
        session.terminal.sendAttachmentReference(snippet.command)
    }
}
