import SwiftUI
import WorkbenchCore
import OpenSSHBackend

/// “连接时进入”对话框中的一个会话。tmux 的 `id` 是 session_id，Zellij/herdr 的 `id` 即会话名。
struct PreferredSession: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let created: Date?
    /// 会话尚不存在，由终端内的工具创建（herdr）。
    var create = false
}

/// 连接主机时进入 tmux、Zellij 或 herdr 会话：零个先确认新建，一个直接进入，多个让用户选择。
@MainActor
final class PreferredTmuxConnection: ObservableObject, Identifiable {
    let id = UUID()
    let host: HostProfile
    let kind: MultiplexerKind
    @Published private(set) var sessions: [PreferredSession] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    var isCurrent: () -> Bool = { true }
    var onConnect: (PreferredSession) -> Void = { _ in }
    private let cancellation = CancellationFlag()
    private let list: @Sendable (CancellationFlag) throws -> [PreferredSession]
    /// nil 表示无法后台创建，确认后交给终端创建。
    private let make: (@Sendable (String, CancellationFlag) throws -> PreferredSession)?
    private let validate: @Sendable (String) throws -> Void

    init(host: HostProfile, service: TmuxService) {
        self.host = host; kind = .tmux
        list = { try service.sessions(cancellation: $0).map(Self.item) }
        make = { try Self.item(service.createSession(name: $0, cancellation: $1)) }
        validate = { _ in }
    }
    init(host: HostProfile, service: MultiplexerService) {
        self.host = host; kind = service.kind
        let kind = service.kind
        list = { try service.sessions(cancellation: $0).filter(\.running).map { PreferredSession(id: $0.name, name: $0.name, detail: kind.title, created: nil) } }
        if service.createsInBackground {
            make = { name, flag in
                let session = try service.createDetached(name: name, cancellation: flag)
                return PreferredSession(id: session.name, name: session.name, detail: kind.title, created: nil)
            }
        } else { make = nil }
        validate = { try kind.validateSessionName($0) }
    }
    nonisolated private static func item(_ session: TmuxSession) -> PreferredSession {
        PreferredSession(id: session.id, name: session.name, detail: L10n.text("\(session.windows) 个窗口 · \(session.attached) 个客户端"), created: session.created)
    }
    func cancel() { cancellation.cancel() }
    private var current: Bool { !cancellation.isCancelled && isCurrent() }
    func refresh() async {
        guard current, !busy else { return }
        busy = true; failure = nil
        defer { busy = false }
        let list = list; let cancellation = cancellation
        do {
            let available = try await Task.detached { try list(cancellation) }.value
            guard current else { return }
            sessions = available; loaded = true
            if available.count == 1 { onConnect(available[0]) }
        } catch { if current { failure = error.localizedDescription } }
    }
    func choose(_ identifier: String) async {
        guard current, !busy, let selected = sessions.first(where: { $0.id == identifier }) else { return }
        busy = true; failure = nil
        defer { busy = false }
        let list = list; let cancellation = cancellation
        do {
            let available = try await Task.detached { try list(cancellation) }.value
            guard current else { return }
            sessions = available
            guard let session = available.first(where: { $0.id == selected.id && $0.created == selected.created }) else {
                failure = L10n.text("所选 \(kind.title) 会话已结束或变化，请重新选择。"); return
            }
            onConnect(session)
        } catch { if current { failure = error.localizedDescription } }
    }
    func create(name: String) async {
        guard current, !busy, loaded, sessions.isEmpty else { return }
        busy = true; failure = nil
        defer { busy = false }
        let list = list; let make = make; let validate = validate; let cancellation = cancellation
        do {
            try validate(name)
            let available = try await Task.detached { try list(cancellation) }.value
            guard current else { return }
            guard available.isEmpty else {
                sessions = available; failure = L10n.text("目标主机已有新的 \(kind.title) 会话，请选择要进入的会话。"); return
            }
            let session: PreferredSession
            if let make { session = try await Task.detached { try make(name, cancellation) }.value }
            else { session = PreferredSession(id: name, name: name, detail: kind.title, created: nil, create: true) }
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
        let tool = request.kind.title
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("打开 \(tool) 工作区")).font(.headline)
            Text(request.host.name).font(.subheadline).textSelection(.enabled)
            Text(verbatim: "\(request.host.address):\(request.host.port)").font(.caption.monospaced()).foregroundStyle(.secondary)
            if !request.loaded {
                Text(request.failure == nil ? L10n.text("正在检测目标主机的 \(tool) 会话…") : L10n.text("暂时无法读取 \(tool)")).foregroundStyle(.secondary)
            } else if request.sessions.isEmpty {
                Text(L10n.text("目标主机没有正在运行的 \(tool) 会话。是否新建并进入？")).fixedSize(horizontal: false, vertical: true)
                TextField(L10n.text("会话名称"), text: $name).textFieldStyle(.roundedBorder).disabled(request.busy)
            } else {
                Text(L10n.text("请选择要进入的 \(tool) 会话。"))
                List(request.sessions, selection: $selectedID) { session in
                    HStack {
                        Image(systemName: "terminal")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.name)
                            Text(session.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.id != session.name { Text(session.id).font(.caption.monospaced()).foregroundStyle(.secondary) }
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
