import SwiftUI
import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class TmuxModel: ObservableObject {
    @Published var sessions: [TmuxSession] = []
    @Published var panes: [TmuxPane] = []
    @Published var busy = false
    @Published var errorMessage: String?
    let service: TmuxService
    init(host: HostProfile?, store: AppStore) { service = TmuxService(transport: store.transport, host: host) }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let service = service
            let result = try await Task.detached { () -> ([TmuxSession], [TmuxPane]) in
                let sessions = try service.sessions(); return (sessions, sessions.isEmpty ? [] : try service.panes())
            }.value
            sessions = result.0; panes = result.1; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func perform(_ operation: @escaping @Sendable (TmuxService) throws -> Void) {
        guard !busy else { return }; busy = true
        let service = service
        Task {
            do { try await Task.detached { try operation(service) }.value; busy = false; await refresh() }
            catch { busy = false; errorMessage = error.localizedDescription }
        }
    }
}

struct TmuxWorkspace: View {
    let host: HostProfile?
    @ObservedObject var store: AppStore
    @ObservedObject var workspace: Workspace
    @StateObject private var model: TmuxModel
    init(host: HostProfile?, store: AppStore, workspace: Workspace) { self.host = host; self.store = store; self.workspace = workspace; _model = StateObject(wrappedValue: TmuxModel(host: host, store: store)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("让工作持续在线").font(.system(size: 23, weight: .semibold))
                    Text(host == nil ? "管理此 Mac 的 tmux，会话不会随终端标签关闭。" : "管理远端 tmux，会话与终端连接各自独立。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新远端会话")
                Button { if let name = promptText("新建 tmux 会话", detail: "会话在当前机器创建，关闭标签不会结束它。", initial: "work") { model.perform { try $0.create(name: name) } } } label: { Label("新建会话", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            HStack(spacing: 14) {
                metric("持久会话", value: model.sessions.count, symbol: "square.stack.3d.up", caption: "保留工作现场")
                metric("终端窗格", value: model.panes.count, symbol: "rectangle.split.2x1", caption: "查看进程与工作目录")
                metric("已附着客户端", value: model.sessions.reduce(0) { $0 + $1.attached }, symbol: "link", caption: "tmux 返回的实时状态")
            }
            if let error = model.errorMessage { ErrorBanner(message: error) { model.errorMessage = nil } }
            if model.sessions.isEmpty && !model.busy {
                EmptyWorkspace(symbol: "square.stack.3d.up", title: model.errorMessage == nil ? "还没有 tmux 会话" : "暂时无法读取 tmux", detail: "没有 tmux 时仍可使用普通终端。\n不会擅自安装或修改配置。", action: "打开普通终端") { if let host { workspace.connect(host) } else { workspace.connectLocal() } }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(model.sessions) { session in sessionCard(session) }
                    }
                }
            }
            HStack(spacing: 8) { Image(systemName: "info.circle"); Text("关闭终端标签只会断开连接。“结束会话”才会终止会话中的任务。") }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(26)
            .task { await model.refresh(); while !Task.isCancelled { try? await Task.sleep(for: .seconds(8)); if !Task.isCancelled { await model.refresh() } } }
    }
    private func metric(_ title: String, value: Int, symbol: String, caption: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); Text("\(value)").font(.system(size: 29, weight: .semibold, design: .rounded)); Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary) }
            Spacer(); Image(systemName: symbol).foregroundStyle(.teal).padding(8).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
    }
    private func sessionCard(_ session: TmuxSession) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").font(.title3).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) { Text(session.name).font(.system(size: 15, weight: .semibold)); Text("\(session.windows) 个窗口 · \(session.attached) 个客户端").font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    Button("新建窗口") { model.perform { try $0.createWindow(session: session.id) } }
                    Button("重命名会话") { if let name = promptText("重命名会话", initial: session.name) { model.perform { try $0.rename(session: session.id, name: name) } } }
                    Divider()
                    Button("结束会话…", role: .destructive) { if confirm("结束“\(session.name)”？", "这会终止此远端会话中的全部窗口、窗格和正在运行的任务，无法撤销。") { model.perform { try $0.kill(session: session.id) } } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            Divider()
            ForEach(model.panes.filter { $0.sessionID == session.id }) { pane in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2).fill(pane.active ? Color.teal : .secondary.opacity(0.3)).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(pane.windowName).fontWeight(.medium); Text("\(pane.id) · \(pane.command)").foregroundStyle(.secondary) }.font(.system(size: 11, design: .monospaced))
                        Text(pane.directory).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Button { model.perform { try $0.select(pane: pane) }; workspace.attachTmux(host, session: session) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("进入此窗格")
                }.contextMenu { Button("横向分割窗格") { model.perform { try $0.split(pane: pane.id) } } }
            }
            HStack { Text(session.created, style: .date).font(.system(size: 10)).foregroundStyle(.tertiary); Spacer(); Button("进入会话") { workspace.attachTmux(host, session: session) }.buttonStyle(.bordered).tint(.teal) }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.quaternary.opacity(0.65)))
    }
}

func promptText(_ title: String, detail: String = "", initial: String = "") -> String? {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
    let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 360, height: 25); alert.accessoryView = field; alert.window.initialFirstResponder = field
    alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 9) { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); Text(message).font(.system(size: 11)).textSelection(.enabled); Spacer(); Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain) }
            .padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
