import AppKit
import Combine
import Network

@MainActor
final class ConnectionRecoveryEvents {
    let events = PassthroughSubject<String, Never>()
    private let monitor = NWPathMonitor()
    private let center = NSWorkspace.shared.notificationCenter
    private var wakeObserver: NSObjectProtocol?
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let event = path.status == .satisfied ? "network_available" : "network_path_changed"
            DispatchQueue.main.async { self?.events.send(event) }
        }
        monitor.start(queue: DispatchQueue(label: "local.sshworkbench.network-path"))
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.events.send("wake") }
        }
    }
    deinit { monitor.cancel(); if let wakeObserver { center.removeObserver(wakeObserver) } }
}
