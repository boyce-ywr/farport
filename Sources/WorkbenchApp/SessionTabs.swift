import SwiftUI
import WorkbenchCore

struct SessionTabs: View {
    @ObservedObject var workspace: Workspace
    @ViewState private var showTabList = false
    @ViewState private var query = ""
    @StateObject private var pointer = TabPointerState()
    var body: some View {
        HStack(spacing: 8) {
            Text(workspace.page == .files ? "文件来源" : "标签组").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: true) {
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
                                        Text(workspace.sessionLabel(session)).lineLimit(1).truncationMode(.middle)
                                        if let tab, tab.terminals.count > 1 { Text("\(tab.terminals.count) 分栏").font(.system(size: 10)).padding(.horizontal, 5).padding(.vertical, 2).background(markColor.opacity(0.12), in: Capsule()) }
                                    }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).frame(minHeight: 32).frame(minWidth: 100, maxWidth: 230).contentShape(Rectangle())
                                }.buttonStyle(.plain).interactionFrame("terminal.\(session.id.uuidString)")
                                    .background { GeometryReader { geometry in TabPointerRegion(identifier: identifier, state: pointer, frame: geometry.frame(in: .named("workspace-interactions")), select: {
                                        if let tab { workspace.chooseTerminalTab(tab.id) } else { workspace.chooseTab(session) }
                                    }, move: { source, destination in
                                        if workspace.page == .files { workspace.reorderFileTab(source, onto: destination) }
                                        else { workspace.reorderTab(payload: "\(workspace.tabDragScope.uuidString):\(source.uuidString)", onto: destination) }
                                    }).frame(width: geometry.size.width, height: geometry.size.height) } }
                                Button { if let tab { workspace.closeTab(tab.id) } else { close(session) } } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 28, height: 32).contentShape(Rectangle()) }.buttonStyle(.plain).help(tab == nil ? "关闭会话" : "关闭此标签的全部分栏")
                            }.background(selected ? markColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .bottom) { if selected { Capsule().fill(markColor).frame(height: 2).padding(.horizontal, 10) } }
                                .id(identifier)
                                .help(workspace.sessionLabel(session) + "\n" + session.subtitle)
                                .opacity(pointer.dragging == identifier ? 0.55 : 1)
                                .overlay { if pointer.target == identifier && pointer.dragging != identifier { RoundedRectangle(cornerRadius: 8).strokeBorder(.teal, lineWidth: 2) } }
                                .contextMenu {
                                    Button("查看此会话的文件") { workspace.browseFiles(.terminal(session.id)) }
                                    Button("回到此终端") { workspace.selectTerminal(session); workspace.page = .terminal }
                                    if let tab {
                                        Divider()
                                        Button("移到最前") { workspace.layout.moveTab(tab.id, before: workspace.layout.tabs.first?.id) }
                                        Button("移到最后") { workspace.layout.moveTab(tab.id, before: nil) }
                                    } else {
                                        Divider()
                                        Button("移到最前") { if let target = workspace.orderedFileSessions.first?.id { workspace.reorderFileTab(session.id, onto: target) } }
                                        Button("移到最后") { if let target = workspace.orderedFileSessions.last?.id { workspace.reorderFileTab(session.id, onto: target) } }
                                    }
                                }
                        }
                    }
                }.onChange(of: workspace.page == .files ? workspace.activeTabID : workspace.layout.selectedTabID) { _, identifier in if let identifier { reader.scrollTo(identifier, anchor: .center) } }
                    .onChange(of: workspace.layout.tabs.map(\.id)) { _, _ in if let identifier = workspace.page == .files ? workspace.activeTabID : workspace.layout.selectedTabID { reader.scrollTo(identifier, anchor: .center) } }
            }
            Button { query = ""; showTabList.toggle() } label: {
                Label("\(displayedSessions.count)", systemImage: "list.bullet").font(.system(size: 11)).frame(minWidth: 42, minHeight: 36)
            }.buttonStyle(.borderless).help("全部标签：搜索、切换与关闭")
                .popover(isPresented: $showTabList) { tabList }
            Menu {
                Button("新建当前主机终端") { workspace.newTerminal() }
                Button("新建本机终端") { workspace.connectLocal() }
                Divider()
                Button("左右分栏 · ⌘D") { workspace.newTerminal(split: true) }
                Button("上下分栏 · ⌘⇧D") { workspace.newTerminal(split: true, axis: .topBottom) }
            } label: { Image(systemName: "plus").frame(width: 28, height: 36) }.menuStyle(.borderlessButton).frame(width: 30)
        }.padding(.horizontal, 10).padding(.vertical, 3)
            .onChange(of: workspace.page) { _, _ in pointer.dragging = nil; pointer.target = nil }
    }
    private var displayedSessions: [TerminalSession] {
        if workspace.page == .files { return workspace.orderedFileSessions }
        return workspace.layout.tabs.compactMap { tab in workspace.sessions.first { $0.id == tab.terminals.first } }
    }
    private var tabList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(workspace.page == .files ? "文件来源" : "全部标签") · \(displayedSessions.count)").font(.headline)
            TextField("搜索主机、会话或地址", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(displayedSessions.filter { query.isEmpty || (workspace.sessionLabel($0) + " " + $0.subtitle).localizedCaseInsensitiveContains(query) }) { session in
                        let tab = workspace.layout.tab(containing: session.id)
                        HStack {
                            Button {
                                if workspace.page == .files { workspace.chooseTab(session) } else if let tab { workspace.chooseTerminalTab(tab.id) }
                                showTabList = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(workspace.sessionLabel(session)).font(.system(size: 12, weight: .medium))
                                    Text(session.subtitle + (workspace.page != .files ? " · \(tab?.terminals.count ?? 1) 分栏" : "")).font(.caption).foregroundStyle(.secondary)
                                }.lineLimit(1).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { if workspace.page == .files { close(session) } else if let tab { workspace.closeTab(tab.id) } } label: { Image(systemName: "xmark").frame(width: 28, height: 32) }.buttonStyle(.borderless).help("关闭")
                        }.padding(.horizontal, 8).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }.frame(height: 320)
            Text(workspace.page == .files ? "文件来源独立排序，拖动不会改变终端分栏与连接。" : "拖动标签可排序；右键可移到最前或最后。分栏与连接不变。").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 380)
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
                Text(workspace.fileSourceName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
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
        }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6).background(.teal.opacity(0.05))
    }
}
