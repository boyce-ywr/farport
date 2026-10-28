import SwiftUI
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class PreferredTmuxConnection: ObservableObject, Identifiable {
    let id = UUID()
    let host: HostProfile
    let service: TmuxService
    @Published private(set) var sessions: [TmuxSession] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    var isCurrent: () -> Bool = { true }
    var onConnect: (TmuxSession) -> Void = { _ in }
    private let cancellation = CancellationFlag()

    init(host: HostProfile, service: TmuxService) { self.host = host; self.service = service }
    func cancel() { cancellation.cancel() }
    private var current: Bool { !cancellation.isCancelled && isCurrent() }
    func refresh() async {
        guard current, !busy else { return }
        busy = true; failure = nil
        defer { busy = false }
        let service = service; let cancellation = cancellation
        do {
            let available = try await Task.detached { try service.sessions(cancellation: cancellation) }.value
            guard current else { return }
            sessions = available; loaded = true
            if available.count == 1 { onConnect(available[0]) }
        } catch { if current { failure = error.localizedDescription } }
    }
    func choose(_ identifier: String) async {
        guard current, !busy, let selected = sessions.first(where: { $0.id == identifier }) else { return }
        busy = true; failure = nil
        defer { busy = false }
        let service = service; let cancellation = cancellation
        do {
            let available = try await Task.detached { try service.sessions(cancellation: cancellation) }.value
            guard current else { return }
            sessions = available
            guard let session = available.first(where: { $0.id == selected.id && $0.created == selected.created }) else {
                failure = L10n.text("所选 tmux 会话已结束或变化，请重新选择。"); return
            }
            onConnect(session)
        } catch { if current { failure = error.localizedDescription } }
    }
    func create(name: String) async {
        guard current, !busy, loaded, sessions.isEmpty else { return }
        busy = true; failure = nil
        defer { busy = false }
        let service = service; let cancellation = cancellation
        do {
            let available = try await Task.detached { try service.sessions(cancellation: cancellation) }.value
            guard current else { return }
            guard available.isEmpty else {
                sessions = available; failure = L10n.text("目标主机已有新的 tmux 会话，请选择要进入的会话。"); return
            }
            let session = try await Task.detached { try service.createSession(name: name, cancellation: cancellation) }.value
            guard current else { return }
            onConnect(session)
        } catch { if current { failure = error.localizedDescription } }
    }
}

struct PreferredTmuxConnectionView: View {
    @ObservedObject var request: PreferredTmuxConnection
    let cancel: () -> Void
    @ViewState private var selectedID: String?
    @ViewState private var name = "work"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("打开 tmux 工作区")).font(.headline)
            Text(request.host.name).font(.subheadline).textSelection(.enabled)
            Text(verbatim: "\(request.host.address):\(request.host.port)").font(.caption.monospaced()).foregroundStyle(.secondary)
            if !request.loaded {
                Text(request.failure == nil ? L10n.text("正在检测目标主机的 tmux 会话…") : L10n.text("暂时无法读取 tmux")).foregroundStyle(.secondary)
            } else if request.sessions.isEmpty {
                Text(L10n.text("目标主机没有正在运行的 tmux 会话。是否新建并进入？")).fixedSize(horizontal: false, vertical: true)
                TextField(L10n.text("会话名称"), text: $name).textFieldStyle(.roundedBorder).disabled(request.busy)
            } else {
                Text(L10n.text("请选择要进入的 tmux 会话。"))
                List(request.sessions, selection: $selectedID) { session in
                    HStack {
                        Image(systemName: "terminal")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.name)
                            Text(L10n.text("\(session.windows) 个窗口 · \(session.attached) 个客户端")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(session.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.tag(session.id)
                }.frame(height: 200).disabled(request.busy)
            }
            if let failure = request.failure { Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L10n.text("取消"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L10n.text("刷新")) { Task { await request.refresh() } }.disabled(request.busy)
                Spacer()
                if request.busy { ProgressView().controlSize(.small) }
                if request.loaded, request.sessions.isEmpty {
                    Button(L10n.text("新建并进入")) { Task { await request.create(name: name) } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(request.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if request.loaded {
                    Button(L10n.text("进入会话")) { if let selectedID { Task { await request.choose(selectedID) } } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(request.busy || !request.sessions.contains(where: { $0.id == selectedID }))
                }
            }
        }.padding(22).frame(width: 460)
            .task { await request.refresh() }
            .onDisappear { request.cancel() }
    }
}
