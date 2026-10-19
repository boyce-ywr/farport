import Foundation
import Network
import Darwin
import WorkbenchCore

extension SSHTransport {
    public func screenSharingArguments(for host: HostProfile, endpoint: ScreenSharingEndpoint) throws -> [String] {
        try options(for: host, reuseConnection: false) + ["-T", "-o", "ClearAllForwardings=yes", "-W", endpoint.forwardingTarget, host.address]
    }
}

public final class ScreenSharingRelay {
    private let queue = DispatchQueue(label: "local.sshworkbench.screen-sharing")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let listener: NWListener
    private var peers: [UUID: ScreenSharingPeer] = [:]
    private var stopped = false
    public init(makeProcess: @escaping () throws -> Process, ready: @escaping (Int) -> Void, failure: @escaping (String) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        queue.setSpecific(key: queueKey, value: true)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !stopped else { return }
            switch state {
            case .ready: if let port = listener.port { ready(Int(port.rawValue)) }
            case .failed(let error): failure(error.localizedDescription); shutdown()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !stopped, peers.count < 8 else { connection.cancel(); return }
            let identifier = UUID()
            let peer = ScreenSharingPeer(connection: connection, queue: queue, makeProcess: makeProcess, failure: failure) { [weak self] in self?.peers.removeValue(forKey: identifier) }
            peers[identifier] = peer; peer.start()
        }
        listener.start(queue: queue)
    }
    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { shutdown() }
        else { queue.sync { shutdown() } }
    }
    private func shutdown() {
        guard !stopped else { return }; stopped = true; listener.cancel()
        let active = Array(peers.values); peers.removeAll(); active.forEach { $0.stop() }
    }
    deinit {
        listener.cancel()
        let active = Array(peers.values)
        queue.async { active.forEach { $0.stop() } }
    }
}

private final class ScreenSharingPeer {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let makeProcess: () throws -> Process
    private let failure: (String) -> Void
    private let finished: () -> Void
    private var process: Process?
    private var input: DispatchIO?
    private var output: DispatchIO?
    private var errors: DispatchIO?
    private var errorText = Data()
    private var closed = false
    init(connection: NWConnection, queue: DispatchQueue, makeProcess: @escaping () throws -> Process, failure: @escaping (String) -> Void, finished: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.makeProcess = makeProcess; self.failure = failure; self.finished = finished
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: launch()
            case .failed, .cancelled: stop()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func channel(_ handle: FileHandle) throws -> DispatchIO {
        let descriptor = dup(handle.fileDescriptor)
        guard descriptor >= 0 else { throw WorkbenchError.message(L10n.text("无法建立桌面数据通道。")) }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(descriptor); throw WorkbenchError.message(L10n.text("无法建立桌面数据通道。")) }
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in Darwin.close(descriptor) }
        channel.setLimit(lowWater: 1)
        return channel
    }
    private func launch() {
        guard !closed else { return }
        do {
            let child = try makeProcess()
            let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
            input = try channel(stdin.fileHandleForWriting)
            output = try channel(stdout.fileHandleForReading)
            errors = try channel(stderr.fileHandleForReading)
            child.terminationHandler = { [weak self] child in
                guard let self else { return }
                queue.async {
                    if !self.closed && child.terminationStatus != 0 {
                        let detail = String(decoding: self.errorText, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        self.failure(detail.isEmpty ? L10n.text("SSH 桌面通道已中断，请检查认证与目标端口。") : detail); self.stop()
                    }
                }
            }
            process = child; try child.run()
            for pipe in [stdin, stdout, stderr] { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            errors?.read(offset: 0, length: Int.max, queue: queue) { [weak self] _, data, _ in
                guard let self, let data else { return }
                if errorText.count < 8192 { errorText.append(Data(data).prefix(8192 - errorText.count)) }
            }
            receive(); readOutput()
        } catch { failure(error.localizedDescription); stop() }
    }
    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !closed else { return }
            if error != nil { stop(); return }
            guard let data, !data.isEmpty else {
                if complete { input?.close(); input = nil } else { receive() }
                return
            }
            let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
            input?.write(offset: 0, data: bytes, queue: queue) { [weak self] done, _, error in
                guard let self, !closed else { return }
                if error != 0 { stop(); return }
                if done {
                    if complete { input?.close(); input = nil } else { receive() }
                }
            }
        }
    }
    private func readOutput() {
        guard !closed else { return }
        var received = 0; var pending = 0; var doneReading = false; var advanced = false
        func advance() {
            guard !closed, doneReading, pending == 0, !advanced else { return }
            advanced = true
            if received == 65536 { readOutput() }
            else { connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.stop() }) }
        }
        output?.read(offset: 0, length: 65536, queue: queue) { [weak self] done, data, error in
            guard let self, !closed else { return }
            if error != 0 { stop(); return }
            if let data, !data.isEmpty {
                received += data.count; pending += 1
                connection.send(content: Data(data), completion: .contentProcessed { [weak self] error in
                    guard let self, !closed else { return }
                    if error != nil { stop(); return }
                    pending -= 1; advance()
                })
            }
            doneReading = done; advance()
        }
    }
    func stop() {
        guard !closed else { return }; closed = true
        connection.cancel(); input?.close(flags: .stop); output?.close(flags: .stop); errors?.close(flags: .stop)
        input = nil; output = nil; errors = nil
        if let process, process.isRunning { process.terminate() }
        finished()
    }
}
