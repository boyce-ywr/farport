import SwiftUI
import WorkbenchCore

struct TerminalWorkspace: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: AppStore
    let addHost: () -> Void
    @ViewState private var search = ""
    var body: some View {
        if workspace.sessions.isEmpty {
            VStack(spacing: 0) {
                EmptyWorkspace(symbol: "terminal", title: "连接远端，保持心流。", detail: "原生终端 · 持久 tmux 会话 · 安全文件传输\n你的工具在这里，远端工作随时继续。", action: workspace.host == nil ? "添加第一台主机" : "打开 SSH 终端") {
                    if let host = workspace.host { workspace.connect(host) } else { addHost() }
                }
                HStack(spacing: 28) {
                    feature("⌘ T", "新建终端"); feature("⌘ ⇧ D", "左右分屏"); feature("⌘ F", "查找内容")
                }.padding(.bottom, 50)
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(workspace.sessions) { session in
                                HStack(spacing: 0) {
                                    Button { workspace.selectTerminal(session) } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: session.tmuxID == nil ? "terminal" : "square.stack.3d.up").foregroundStyle(.teal)
                                            Text(session.host.name).lineLimit(1).frame(maxWidth: 140)
                                        }.padding(.horizontal, 12).frame(minWidth: 125, minHeight: 36).contentShape(Rectangle())
                                    }.buttonStyle(.plain).interactionFrame("terminal.\(session.id.uuidString)")
                                    Button { close(session) } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 28, height: 36).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary)
                                }.font(.system(size: 11, weight: .medium))
                                    .background(workspace.selectedTerminalID == session.id ? Color.teal.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                    Button { if let host = workspace.host { workspace.connect(host) } } label: { Image(systemName: "plus") }.buttonStyle(.borderless).padding(.horizontal, 12)
                }.padding(.horizontal, 15).padding(.vertical, 9)
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("搜索终端内容", text: $search).textFieldStyle(.plain).onSubmit { _ = workspace.selectedTerminal?.terminal.findNext(search) }
                    Button { _ = workspace.selectedTerminal?.terminal.findPrevious(search) } label: { Image(systemName: "chevron.up") }
                    Button { _ = workspace.selectedTerminal?.terminal.findNext(search) } label: { Image(systemName: "chevron.down") }
                    Spacer()
                    if let session = workspace.selectedTerminal {
                        TerminalStatus(session: session, showReconnect: true)
                    }
                }.buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 18).padding(.vertical, 10)
                Divider()
                if let session = workspace.primaryTerminal {
                    HSplitView {
                        TerminalSurface(session: session, store: store).id(session.id).frame(minWidth: 240)
                        if let split = workspace.sessions.first(where: { $0.id == workspace.splitTerminalID }), split.id != session.id {
                            VStack(spacing: 0) {
                                HStack { Button(split.host.name) { workspace.selectTerminal(split) }.buttonStyle(.plain).font(.caption); Spacer(); Button { workspace.collapseSplit() } label: { Image(systemName: "rectangle") }.buttonStyle(.plain).help("结束分屏，保留终端") }.padding(9)
                                TerminalSurface(session: split, store: store).id(split.id)
                            }.frame(minWidth: 240)
                        }
                    }.padding(12)
                } else {
                    EmptyWorkspace(symbol: "terminal", title: "此主机尚未打开终端", detail: "选择此主机的终端标签，或建立新的 SSH 连接。", action: "打开 SSH 终端") { if let host = workspace.host { workspace.connect(host) } }
                }
            }
        }
    }
    private func feature(_ shortcut: String, _ title: String) -> some View {
        HStack(spacing: 8) { Text(shortcut).font(.system(size: 11, design: .monospaced)).padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5)); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func close(_ session: TerminalSession) {
        if session.connected, !confirm("断开此终端？", session.tmuxID == nil ? "普通 SSH 中正在运行的前台任务可能随连接结束。需要保留的工作请使用 tmux。" : "仅断开连接，不会结束远端 tmux 会话。") { return }
        workspace.close(session)
    }
}

struct TerminalStatus: View {
    @ObservedObject var session: TerminalSession
    let showReconnect: Bool
    var body: some View {
        HStack(spacing: 10) {
            Label(session.state, systemImage: session.connected ? "circle.fill" : "circle").font(.system(size: 10)).foregroundStyle(session.connected ? .teal : .secondary)
            if showReconnect { Button("重连") { session.reconnect() }.font(.caption) }
            else { Text(session.dimensions).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }
}
