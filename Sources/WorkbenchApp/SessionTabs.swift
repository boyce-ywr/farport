import SwiftUI
import WorkbenchCore

struct SessionTabs: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        HStack(spacing: 8) {
            Text(workspace.page == .files ? "文件来源" : "标签组").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(displayedSessions) { session in
                            let tab = workspace.page == .files ? nil : workspace.layout.tab(containing: session.id)
                            let identifier = tab?.id ?? session.id
                            let selected = workspace.page == .files ? workspace.activeTabID == session.id : workspace.layout.selectedTabID == identifier
                            let markColor = (workspace.store.hosts.first(where: { $0.id == session.host?.id }) ?? session.host)?.markColor ?? .teal
                            HStack(spacing: 0) {
                                Button { if let tab { workspace.chooseTerminalTab(tab.id) } else { workspace.chooseTab(session) } } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: session.tmuxID == nil ? "terminal" : "square.stack.3d.up").foregroundStyle(markColor)
                                        Text(workspace.sessionLabel(session)).lineLimit(1)
                                        if let tab, tab.terminals.count > 1 { Text("\(tab.terminals.count) 分栏").font(.system(size: 10)).padding(.horizontal, 5).padding(.vertical, 2).background(markColor.opacity(0.12), in: Capsule()) }
                                    }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).frame(minHeight: 38).contentShape(Rectangle())
                                }.buttonStyle(.plain).interactionFrame("terminal.\(session.id.uuidString)")
                                Button { if let tab { workspace.closeTab(tab.id) } else { close(session) } } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 28, height: 38).contentShape(Rectangle()) }.buttonStyle(.plain).help(tab == nil ? "关闭会话" : "关闭此标签的全部分栏")
                            }.background(selected ? markColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .bottom) { if selected { Capsule().fill(markColor).frame(height: 2).padding(.horizontal, 10) } }
                                .id(identifier)
                                .contextMenu {
                                    Button("查看此会话的文件") { workspace.browseFiles(.terminal(session.id)) }
                                    Button("回到此终端") { workspace.selectTerminal(session); workspace.page = .terminal }
                                }
                        }
                    }
                }.onChange(of: workspace.page == .files ? workspace.activeTabID : workspace.layout.selectedTabID) { _, identifier in if let identifier { reader.scrollTo(identifier, anchor: .center) } }
            }
            Menu {
                Button("新建当前主机终端") { workspace.newTerminal() }
                Button("新建本机终端") { workspace.connectLocal() }
                Divider()
                Button("左右分栏 · ⌘D") { workspace.newTerminal(split: true) }
                Button("上下分栏 · ⌘⇧D") { workspace.newTerminal(split: true, axis: .topBottom) }
            } label: { Image(systemName: "plus").frame(width: 28, height: 36) }.menuStyle(.borderlessButton).frame(width: 30)
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
    private var displayedSessions: [TerminalSession] {
        if workspace.page == .files { return workspace.sessions }
        return workspace.layout.tabs.compactMap { tab in workspace.sessions.first { $0.id == tab.terminals.first } }
    }
    private func close(_ session: TerminalSession) {
        let detail = session.tmuxID != nil ? "只分离此终端，tmux 会话继续运行。" : "当前 Shell 和前台任务可能随连接关闭。"
        if session.connected && !confirm("关闭此会话？", detail) { return }
        workspace.close(session)
    }
}

struct FileSourceBar: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.person.crop").foregroundStyle(workspace.fileHost?.markColor ?? .teal)
            VStack(alignment: .leading, spacing: 4) {
                Text("当前文件来源").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(workspace.fileSourceName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(workspace.fileHost?.subtitle ?? "本机文件系统").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                Section("已打开的终端") {
                    ForEach(workspace.sessions) { session in Button(workspace.sessionLabel(session)) { workspace.browseFiles(.terminal(session.id)) } }
                }
                Section("按主机浏览") {
                    Button("此 Mac") { workspace.browseFiles(.local) }
                    ForEach(workspace.store.hosts) { host in Button(host.name) { workspace.browseFiles(.host(host.id)) } }
                }
            } label: { Label("切换文件来源", systemImage: "arrow.left.arrow.right") }.menuStyle(.borderlessButton).frame(maxWidth: 150)
            Button("回到对应终端") { workspace.openFileSourceTerminal() }.disabled(!workspace.fileSourceAvailable)
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.teal.opacity(0.05))
    }
}
