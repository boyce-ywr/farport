import AppKit
import SwiftUI
import WorkbenchCore

@MainActor
final class FilePane: ObservableObject, Identifiable {
    let id = UUID()
    @Published var source: FileBrowserSource?
    private var browsers: [FileBrowserSource: FileModel] = [:]
    init(source: FileBrowserSource?) { self.source = source }
    func browser(for source: FileBrowserSource, host: HostProfile?, store: AppStore, showPreview: Bool) -> FileModel {
        if let existing = browsers[source], existing.host?.connectionKey == host?.connectionKey { return existing }
        browsers[source]?.stop()
        let browser = FileModel(host: host, store: store)
        browser.showPreview = showPreview
        browsers[source] = browser; return browser
    }
    func remove(_ source: FileBrowserSource) { browsers.removeValue(forKey: source)?.stop() }
    func stop() { browsers.values.forEach { $0.stop() } }
}

extension Workspace {
    var focusedFilePane: FilePane? { filePanes.first { $0.id == fileLayout.focused } }
    func fileHost(for source: FileBrowserSource?) -> HostProfile? {
        switch source {
        case .terminal(let identifier): return sessions.first { $0.id == identifier }?.host
        case .host(let identifier): return store.hosts.first { $0.id == identifier }
        default: return nil
        }
    }
    func fileSourceAvailable(_ source: FileBrowserSource?) -> Bool {
        switch source {
        case .terminal(let identifier): return sessions.contains { $0.id == identifier }
        case .host(let identifier): return store.hosts.contains { $0.id == identifier }
        case .local: return true
        case nil: return false
        }
    }
    func fileBrowser(in pane: FilePane) -> FileModel? {
        guard let source = pane.source, fileSourceAvailable(source) else { return nil }
        return pane.browser(for: source, host: fileHost(for: source), store: store, showPreview: filePanes.count == 1)
    }
    func focusFilePane(_ identifier: UUID, requestKeyboard: Bool = true) {
        guard let pane = filePanes.first(where: { $0.id == identifier }) else { return }
        if fileLayout.focused != identifier { fileLayout.select(identifier) }
        if requestKeyboard, let model = fileBrowser(in: pane) {
            if let window = model.tableView?.window, window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil { window.makeFirstResponder(nil) }
            model.focusRequest &+= 1
        }
    }
    func selectFileSource(_ source: FileBrowserSource, in pane: FilePane) {
        focusFilePane(pane.id, requestKeyboard: false); fileSource = source
    }
    func splitFilePane(axis: TerminalSplitAxis = .leftRight) {
        guard filePanes.count < 8 else { store.errorMessage = L10n.text("最多打开 8 个文件分栏，请先关闭不需要的分栏。"); return }
        if fileSource == nil { fileSource = host.map { .host($0.id) } ?? .local }
        guard let original = focusedFilePane else { return }
        let previous = fileBrowser(in: original)
        let pane = FilePane(source: original.source)
        filePanes.append(pane); fileLayout.split(with: pane.id, axis: axis)
        if let browser = fileBrowser(in: pane) {
            previous?.showPreview = false; browser.showPreview = false
            browser.loadIfNeeded(previous?.path)
            browser.focusRequest &+= 1
        }
    }
    func closeFilePane(_ identifier: UUID) {
        guard filePanes.count > 1, let pane = filePanes.first(where: { $0.id == identifier }) else { return }
        pane.stop(); filePanes.removeAll { $0.id == identifier }; fileLayout.close(identifier)
        currentFileBrowser?.focusRequest &+= 1
    }
    func splitCurrentWorkspace(axis: TerminalSplitAxis = .leftRight) {
        if page == .files { splitFilePane(axis: axis) }
        else if page == .terminal { newTerminal(split: true, axis: axis) }
    }
}

struct FilePaneWorkspace: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            FileSourceBar(workspace: workspace)
            Divider()
            if let tab = workspace.fileLayout.selectedTab {
                GeometryReader { geometry in
                    let bounds = CGRect(origin: .zero, size: geometry.size)
                    let layout = WorkspacePaneGeometry(root: tab.root, bounds: bounds)
                    ZStack(alignment: .topLeading) {
                        ForEach(workspace.filePanes) { pane in
                            if let rectangle = layout.panes[pane.id] {
                                let frame = tab.zoomed && tab.focused == pane.id ? bounds : rectangle
                                let visible = !tab.zoomed || tab.focused == pane.id
                                FilePaneView(pane: pane, workspace: workspace, store: store, visible: visible)
                                    .frame(width: frame.width, height: frame.height).clipped()
                                    .position(x: frame.midX, y: frame.midY)
                                    .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                            }
                        }
                        if !tab.zoomed {
                            ForEach(layout.dividers) { divider in
                                Rectangle().fill(Color.primary.opacity(0.12)).contentShape(Rectangle())
                                    .frame(width: divider.frame.width, height: divider.frame.height)
                                    .position(x: divider.frame.midX, y: divider.frame.midY)
                                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(tab.id)).onChanged { value in
                                        let horizontal = divider.axis == .leftRight
                                        let length = (horizontal ? divider.container.width : divider.container.height) - 6
                                        guard length > 0 else { return }
                                        let location = horizontal ? value.location.x - divider.container.minX : value.location.y - divider.container.minY
                                        workspace.fileLayout.resize(divider.id, ratio: (location - 3) / length)
                                    })
                                    .onHover { inside in
                                        if inside { (divider.axis == .leftRight ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
                                        else { NSCursor.arrow.set() }
                                    }
                            }
                        }
                    }.coordinateSpace(name: tab.id)
                }
            } else { Text(L10n.text("请选择有效的文件来源")).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
}

private struct FilePaneView: View {
    @ObservedObject var pane: FilePane
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: AppStore
    let visible: Bool
    private var focused: Bool { workspace.fileLayout.focused == pane.id }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(focused ? Color.teal : .secondary.opacity(0.4)).frame(width: 6, height: 6)
                Menu {
                    Button(L10n.text("此 Mac")) { workspace.selectFileSource(.local, in: pane) }
                    ForEach(store.hosts) { host in Button(host.name) { workspace.selectFileSource(.host(host.id), in: pane) } }
                    if !workspace.sessions.isEmpty {
                        Divider()
                        ForEach(workspace.sessions) { session in Button(workspace.sessionLabel(session)) { workspace.selectFileSource(.terminal(session.id), in: pane) } }
                    }
                } label: {
                    Text(workspace.fileSourceAvailable(pane.source) ? workspace.fileHost(for: pane.source)?.name ?? L10n.text("此 Mac") : L10n.text("文件来源已失效"))
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }.menuStyle(.borderlessButton).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Menu {
                    Button(L10n.text("左右分栏 · ⌘D")) { workspace.focusFilePane(pane.id); workspace.splitFilePane() }
                    Button(L10n.text("上下分栏 · ⌘⇧D")) { workspace.focusFilePane(pane.id); workspace.splitFilePane(axis: .topBottom) }
                    Button(L10n.text("最大化 / 还原当前分栏")) { workspace.focusFilePane(pane.id); workspace.fileLayout.toggleZoom() }
                } label: { Image(systemName: "rectangle.split.2x1") }.menuStyle(.borderlessButton).frame(width: 24)
                if workspace.filePanes.count > 1 {
                    Button { workspace.closeFilePane(pane.id) } label: { Image(systemName: "xmark") }.help(L10n.text("关闭文件分栏"))
                }
            }.buttonStyle(.borderless).padding(.horizontal, 10).frame(height: 30)
                .background(focused ? Color.teal.opacity(0.08) : Color.clear)
                .contentShape(Rectangle()).onTapGesture { workspace.focusFilePane(pane.id) }
            Divider()
            if let model = workspace.fileBrowser(in: pane) {
                FileWorkspace(model: model, store: store, keyboardFocused: focused, visible: visible,
                              focus: { workspace.focusFilePane(pane.id, requestKeyboard: false) },
                              canReceiveFiles: {
                                  workspace.page == .files && workspace.filePanes.contains(where: { $0.id == pane.id })
                                      && workspace.fileLayout.selectedTab.map { !$0.zoomed || $0.focused == pane.id } == true
                                      && workspace.fileBrowser(in: pane) === model
                              })
                    .id(model.id)
            } else { Text(L10n.text("请选择有效的文件来源")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(FilePaneFocus(visible: visible) { workspace.focusFilePane(pane.id, requestKeyboard: false) })
            .overlay { Rectangle().stroke(focused ? Color.teal.opacity(0.65) : .clear, lineWidth: 1).allowsHitTesting(false) }
    }
}

private struct FilePaneFocus: NSViewRepresentable {
    let visible: Bool
    let focus: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak coordinator = context.coordinator] event in
            if let coordinator, coordinator.visible, let view = coordinator.view, view.window === event.window,
               view.convert(view.bounds, to: nil).contains(event.locationInWindow) { coordinator.focus?() }
            return event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.visible = visible; context.coordinator.focus = focus }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }; coordinator.monitor = nil
    }
    final class Coordinator {
        weak var view: NSView?
        var visible = false
        var focus: (() -> Void)?
        var monitor: Any?
    }
}
