import SwiftUI
import WorkbenchCore

struct TerminalWorkspace: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: AppStore
    let addHost: () -> Void
    @ViewState private var search = ""
    @FocusState private var searchFocused: Bool
    var body: some View {
        if workspace.sessions.isEmpty {
            VStack(spacing: 0) {
                EmptyWorkspace(symbol: "terminal", title: L10n.text("连接工作，保持心流。"), detail: L10n.text("本机与 SSH，共享同一套原生终端体验。\n多标签、分屏与搜索，让工作随时继续。"), action: workspace.host == nil ? L10n.text("打开本机终端") : L10n.text("打开 SSH 终端")) {
                    workspace.newTerminal()
                }
                if workspace.host == nil { Button(L10n.text("添加 SSH 主机"), action: addHost).buttonStyle(.link).padding(.bottom, 20) }
                HStack(spacing: 28) {
                    feature("⌘ T", L10n.text("新建标签")); feature("⌘ D / ⌘ ⇧ D", L10n.text("左右 / 上下分栏")); feature("⌘ F", L10n.text("查找内容"))
                }.padding(.bottom, 50)
            }
        } else {
            VStack(spacing: 0) {
                if workspace.showTerminalSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField(L10n.text("搜索终端内容"), text: $search).textFieldStyle(.plain).onSubmit { _ = workspace.selectedTerminal?.terminal.findNext(search) }
                        .focused($searchFocused).onAppear { searchFocused = true }
                    Button { _ = workspace.selectedTerminal?.terminal.findPrevious(search) } label: { Image(systemName: "chevron.up") }
                    Button { _ = workspace.selectedTerminal?.terminal.findNext(search) } label: { Image(systemName: "chevron.down") }
                    Spacer()
                    Button { workspace.chooseAttachments() } label: { Label(L10n.text("发送附件"), systemImage: "paperclip") }
                        .help(L10n.text("粘贴剪贴板图片或拖入文件也可发送；校验目标可读后插入路径，不自动回车"))
                        .disabled(workspace.selectedTerminal?.connected != true)
                    if let session = workspace.selectedTerminal {
                        TerminalStatus(session: session, showReconnect: true)
                    }
                    Button { workspace.showTerminalSearch = false; workspace.selectedTerminal?.terminal.clearSearch() } label: { Image(systemName: "xmark") }.help(L10n.text("关闭搜索"))
                }.buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                }
                if workspace.layout.selectedTab != nil {
                    ZStack {
                        ForEach(workspace.layout.tabs) { tab in
                            TerminalTabContent(tab: tab, workspace: workspace, store: store)
                                .opacity(workspace.layout.selectedTabID == tab.id ? 1 : 0)
                                .allowsHitTesting(workspace.layout.selectedTabID == tab.id)
                                .accessibilityHidden(workspace.layout.selectedTabID != tab.id)
                                .zIndex(workspace.layout.selectedTabID == tab.id ? 1 : 0)
                        }
                    }.padding(4)
                        .onChange(of: workspace.selectedTerminalID) { _, identifier in
                            DispatchQueue.main.async {
                                guard workspace.selectedTerminalID == identifier, let session = workspace.selectedTerminal else { return }
                                session.terminal.window?.makeFirstResponder(session.terminal)
                            }
                        }
                } else {
                    EmptyWorkspace(symbol: "terminal", title: L10n.text("此主机尚未打开终端"), detail: L10n.text("选择终端标签，或打开一个新的终端。"), action: workspace.host == nil ? L10n.text("打开本机终端") : L10n.text("打开 SSH 终端")) { workspace.newTerminal() }
                }
            }
        }
    }
    private func feature(_ shortcut: String, _ title: String) -> some View {
        HStack(spacing: 8) { Text(shortcut).font(.system(size: 11, design: .monospaced)).padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5)); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
}

private struct TerminalDivider: Identifiable {
    let id: UUID
    let axis: TerminalSplitAxis
    let container: CGRect
    let frame: CGRect
}

private struct TerminalPaneGeometry {
    var panes: [UUID: CGRect] = [:]
    var dividers: [TerminalDivider] = []
    init(root: TerminalPaneNode, bounds: CGRect) { arrange(root, in: bounds) }
    private mutating func arrange(_ node: TerminalPaneNode, in bounds: CGRect) {
        switch node {
        case .terminal(let identifier): panes[identifier] = bounds
        case .split(let identifier, let axis, let ratio, let first, let second):
            let vertical = axis == .leftRight
            let length = max(0, (vertical ? bounds.width : bounds.height) - 6)
            let minimum = min(vertical ? 140.0 : 90.0, length / 2)
            let leading = min(length - minimum, max(minimum, length * ratio))
            let firstFrame = CGRect(x: bounds.minX, y: bounds.minY, width: vertical ? leading : bounds.width, height: vertical ? bounds.height : leading)
            let dividerFrame = CGRect(x: vertical ? bounds.minX + leading : bounds.minX, y: vertical ? bounds.minY : bounds.minY + leading,
                                      width: vertical ? 6 : bounds.width, height: vertical ? bounds.height : 6)
            let secondFrame = CGRect(x: vertical ? dividerFrame.maxX : bounds.minX, y: vertical ? bounds.minY : dividerFrame.maxY,
                                     width: vertical ? length - leading : bounds.width, height: vertical ? bounds.height : length - leading)
            dividers.append(TerminalDivider(id: identifier, axis: axis, container: bounds, frame: dividerFrame))
            arrange(first, in: firstFrame); arrange(second, in: secondFrame)
        }
    }
}

private struct TerminalTabContent: View {
    let tab: TerminalTab
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: AppStore
    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let layout = TerminalPaneGeometry(root: tab.root, bounds: bounds)
            ZStack(alignment: .topLeading) {
                ForEach(tab.terminals, id: \.self) { identifier in
                    if let session = workspace.sessions.first(where: { $0.id == identifier }), let pane = layout.panes[identifier] {
                        let frame = tab.zoomed && tab.focused == identifier ? bounds : pane
                        let visible = workspace.layout.selectedTabID == tab.id && (!tab.zoomed || tab.focused == identifier)
                        TerminalPane(session: session, workspace: workspace, store: store, focused: visible && tab.focused == identifier, zoomed: tab.zoomed)
                            .frame(width: frame.width, height: frame.height).clipped()
                            .position(x: frame.midX, y: frame.midY)
                            .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                    }
                }
                if !tab.zoomed {
                    ForEach(layout.dividers) { divider in
                        Rectangle().fill(Color.primary.opacity(0.09)).contentShape(Rectangle())
                            .frame(width: divider.frame.width, height: divider.frame.height)
                            .position(x: divider.frame.midX, y: divider.frame.midY)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(tab.id)).onChanged { value in
                                let vertical = divider.axis == .leftRight
                                let length = (vertical ? divider.container.width : divider.container.height) - 6
                                guard length > 0 else { return }
                                let location = vertical ? value.location.x - divider.container.minX : value.location.y - divider.container.minY
                                workspace.layout.resize(divider.id, ratio: (location - 3) / length)
                            })
                            .onHover { inside in
                                if inside { (divider.axis == .leftRight ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() } else { NSCursor.arrow.set() }
                            }
                    }
                }
            }.coordinateSpace(name: tab.id)
        }
    }
}

private struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: AppStore
    let focused: Bool
    let zoomed: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button { workspace.selectTerminal(session) } label: {
                    HStack(spacing: 7) {
                        Circle().fill(focused ? Color.teal : .secondary.opacity(0.35)).frame(width: 6, height: 6)
                        Text(workspace.sessionLabel(session)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).interactionFrame("pane.\(session.id.uuidString)")
                TerminalClipboardControls(terminal: session.terminal, state: session.terminal.clipboard)
                Button { workspace.browseFiles(.terminal(session.id)) } label: { Image(systemName: "folder").frame(width: 24, height: 30) }.help(L10n.text("查看此分栏的文件"))
                Menu {
                    Button(session.restartLabel) {
                        if session.isLocal && session.connected && !confirm(L10n.text("重新打开本机终端？"), L10n.text("当前 Shell 及其任务可能被结束。")) { return }
                        session.reconnect()
                    }
                    Divider()
                    Button(L10n.text("左右分栏 · ⌘D")) { workspace.selectTerminal(session); workspace.newTerminal(split: true) }
                    Button(L10n.text("上下分栏 · ⌘⇧D")) { workspace.selectTerminal(session); workspace.newTerminal(split: true, axis: .topBottom) }
                    Button(zoomed ? L10n.text("还原分栏 · ⌘⇧↩") : L10n.text("最大化分栏 · ⌘⇧↩")) { workspace.selectTerminal(session); workspace.togglePaneZoom() }
                } label: { Image(systemName: "rectangle.split.2x1") }.menuStyle(.borderlessButton).frame(width: 24)
                Button { workspace.confirmClosePane(session) } label: { Image(systemName: "xmark").frame(width: 24, height: 30) }.help(L10n.text("仅关闭此分栏"))
            }.font(.system(size: 10, weight: focused ? .semibold : .regular)).buttonStyle(.borderless).padding(.horizontal, 8)
                .background(focused ? Color.teal.opacity(0.12) : Color.primary.opacity(0.035))
            TerminalSurface(session: session, store: store, focused: focused)
                .overlay(alignment: .topTrailing) { TerminalClipboardFeedback(state: session.terminal.clipboard).padding(8) }
        }.overlay { Rectangle().strokeBorder(focused ? Color.teal.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: 1).allowsHitTesting(false) }
    }
}

struct TerminalStatus: View {
    @ObservedObject var session: TerminalSession
    let showReconnect: Bool
    var body: some View {
        HStack(spacing: 10) {
            Label(session.state, systemImage: session.connected ? "circle.fill" : "circle").font(.system(size: 10)).foregroundStyle(session.connected ? .teal : .secondary)
            if showReconnect {
                Button(session.restartLabel) {
                    if session.isLocal && session.connected && !confirm(L10n.text("重新打开本机终端？"), L10n.text("当前 Shell 及其任务可能被结束，将从用户主目录启动新的登录 Shell。")) { return }
                    session.reconnect()
                }.font(.caption)
            }
            else { Text(session.dimensions).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }
}
