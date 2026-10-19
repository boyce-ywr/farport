import AppKit
import SwiftUI
import WorkbenchCore
import OpenSSHBackend

@MainActor
final class WebServiceSession: ObservableObject, Identifiable {
    let id = UUID()
    let service: ForwardedService
    @Published private(set) var running = true
    @Published private(set) var state = L10n.text("正在验证 SSH 连接…")
    @Published private(set) var url: URL?
    private let cancellation = CancellationFlag()
    private var relay: ScreenSharingRelay?
    private var stopped = false
    init(host: HostProfile, service: ForwardedService, transport: SSHTransport, opener: ((URL) -> Bool)? = nil) throws {
        try service.validate()
        guard host.id == service.hostID, host.connectionKey == service.connectionKey else {
            throw WorkbenchError.message(L10n.text("主机连接配置已变化，请重新保存服务模板。"))
        }
        self.service = service
        let endpoint = try ScreenSharingEndpoint(host: service.target, port: service.port)
        let arguments = try transport.options(for: host) + ["-T", "-o", "ClearAllForwardings=yes", "-W", endpoint.forwardingTarget, host.address]
        let environment = transport.environment(for: host); let cancellation = cancellation
        Task { [weak self] in
            do {
                _ = try await Task.detached { try transport.run(host, command: SSHTransport.connectionProbe, cancellation: cancellation, timeout: 120).checked() }.value
                guard let self, !stopped else { return }
                relay = try ScreenSharingRelay(makeProcess: {
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = arguments; process.environment = environment; return process
                }, ready: { [weak self] port in
                    DispatchQueue.main.async {
                        guard let self, !self.stopped else { return }
                        do {
                            let url = try service.localURL(port: port); self.url = url
                            let opened = opener?(url) ?? NSWorkspace.shared.open(url)
                            if opened { self.state = L10n.text("已打开本机入口；网页是否可用请以浏览器结果为准。") }
                            else { self.stop(); self.state = L10n.text("浏览器未能打开服务地址。") }
                        } catch { self.stop(); self.state = error.localizedDescription }
                    }
                }, failure: { [weak self] message in
                    DispatchQueue.main.async { guard let self, !self.stopped else { return }; self.stop(); self.state = message }
                })
            } catch { guard let self, !stopped else { return }; stop(); state = error.localizedDescription }
        }
    }
    func stop() { stopped = true; cancellation.cancel(); relay?.stop(); relay = nil; running = false; state = L10n.text("服务通道已停止") }
    deinit { cancellation.cancel(); relay?.stop() }
}

struct WebServicesView: View {
    let host: HostProfile
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: ForwardedService
    @ViewState private var message: String?
    init(host: HostProfile, store: AppStore) {
        self.host = host; self.store = store
        _draft = .init(initialValue: ForwardedService(hostID: host.id, connectionKey: host.connectionKey))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L10n.text("远端网页与服务模板")).font(.title2); Spacer(); Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("\(host.name) · \(host.subtitle)").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach((store.workspaceTools.services ?? []).filter { $0.hostID == host.id }) { service in
                            Button { draft = service; message = nil } label: {
                                VStack(alignment: .leading) { Text(service.name); Text("\(service.target):\(service.port)\(service.path)").font(.caption.monospaced()).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.buttonStyle(.plain)
                        }
                        Button(L10n.text("新建模板")) { draft = ForwardedService(hostID: host.id, connectionKey: host.connectionKey); message = nil }
                    }
                }.frame(width: 220)
                VStack(alignment: .leading, spacing: 10) {
                    TextField(L10n.text("服务名称"), text: $draft.name)
                    TextField(L10n.text("SSH 主机可访问的目标地址"), text: $draft.target)
                    HStack { TextField(L10n.text("远端端口"), value: $draft.port, format: .number.grouping(.never)); Picker(L10n.text("协议"), selection: $draft.scheme) { Text("HTTP").tag("http"); Text("HTTPS").tag("https") }.frame(width: 180) }
                    TextField(L10n.text("路径，例如 /lab"), text: $draft.path)
                    HStack {
                        Button(L10n.text("删除模板"), role: .destructive) { store.workspaceTools.services?.removeAll { $0.id == draft.id }; store.saveWorkspaceTools(); draft = ForwardedService(hostID: host.id, connectionKey: host.connectionKey) }
                        Spacer()
                        Button(L10n.text("保存模板")) { save() }
                        Button(L10n.text("连接并打开")) { connect() }.buttonStyle(.borderedProminent)
                    }
                }.textFieldStyle(.roundedBorder)
            }.frame(height: 210)
            Text(L10n.text("仅监听本机回环地址，保留服务自身登录与 HTTPS 证书校验；不要在模板中保存令牌。页面外链不保证经过 SSH。")) .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            Divider()
            Text(L10n.text("关闭面板或终端不会关闭服务通道；退出 Farport 会停止通道。")) .font(.caption).foregroundStyle(.secondary)
            ScrollView { VStack(spacing: 8) { ForEach(store.webServices.filter { $0.service.hostID == host.id }) { session in WebServiceRow(session: session) } } }.frame(height: 120)
        }.padding(22).frame(width: 760)
    }
    private func save() {
        do {
            try draft.validate(); draft.connectionKey = host.connectionKey
            var services = store.workspaceTools.services ?? []
            if let index = services.firstIndex(where: { $0.id == draft.id }) { services[index] = draft } else { services.append(draft) }
            store.workspaceTools.services = services
            message = store.flushWorkspaceTools() ? L10n.text("服务模板已保存到本机。") : store.errorMessage
        } catch { message = error.localizedDescription }
    }
    private func connect() {
        do {
            guard store.hosts.contains(where: { $0.id == host.id && $0.connectionKey == host.connectionKey }) else { throw WorkbenchError.message(L10n.text("主机连接配置已变化，请重新保存服务模板。")) }
            store.webServices.removeAll { !$0.running }
            guard store.webServices.count < 8 else { throw WorkbenchError.message(L10n.text("请先停止不再使用的服务通道。")) }
            store.webServices.append(try WebServiceSession(host: host, service: draft, transport: store.transport)); message = nil
        } catch { message = error.localizedDescription }
    }
}

private struct WebServiceRow: View {
    @ObservedObject var session: WebServiceSession
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) { Text(session.service.name).font(.headline); Text(session.state).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let url = session.url, session.running { Button(L10n.text("打开网页")) { NSWorkspace.shared.open(url) } }
            if session.running { Button(L10n.text("停止通道")) { session.stop() } }
        }.padding(8).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }
}
