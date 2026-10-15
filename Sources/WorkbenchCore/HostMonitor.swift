import Foundation

public enum MonitorPlatform: String, Codable, Sendable { case linux, macOS, windows, termux }

public struct MonitorProcess: Identifiable, Sendable {
    public let id: Int
    public let user: String
    public let name: String
    public let identity: String
    public let residentBytes: Double?
    public let cpuSeconds: Double?
    public let elapsedSeconds: Double?
    public var cpuPercent: Double?
}

public struct MonitorNetwork: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let receivedBytes: Double
    public let sentBytes: Double
    public var receiveRate: Double?
    public var sendRate: Double?
}

public struct MonitorDisk: Identifiable, Sendable {
    public var id: String { mount }
    public let mount: String
    public let totalBytes: Double
    public let usedBytes: Double
    public let availableBytes: Double
}

public struct MonitorPort: Identifiable, Sendable {
    public var id: String { [transport, local, remote, state, pid.map(String.init) ?? ""].joined(separator: "|") }
    public let transport: String
    public let local: String
    public let remote: String
    public let state: String
    public let pid: Int?
}

public struct MonitorSnapshot: Sendable {
    public var date: Date
    public var platform: MonitorPlatform
    public var info: [String: String] = [:]
    public var warnings: [String] = []
    public var memoryTotal: Double?
    public var memoryUsed: Double?
    public var uptime: Double?
    public var cpuTotal: Double?
    public var cpuIdle: Double?
    public var cpuPercent: Double?
    public var processes: [MonitorProcess] = []
    public var networks: [MonitorNetwork] = []
    public var disks: [MonitorDisk] = []
    public var ports: [MonitorPort] = []
    public init(platform: MonitorPlatform, date: Date = Date()) { self.platform = platform; self.date = date }

    public static func parse(_ text: String, platform: MonitorPlatform, date: Date = Date()) throws -> Self {
        let lines = text.components(separatedBy: .newlines)
        guard let marker = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{feff}", with: "") == "FARPORT_MONITOR_V1" }) else {
            throw WorkbenchError.message(L10n.text("监控响应无法识别；未展示推测数据。"))
        }
        var snapshot = Self(platform: platform, date: date)
        func number(_ text: String) -> Double? { guard let value = Double(text), value.isFinite, value >= 0 else { return nil }; return value }
        for line in lines.dropFirst(marker + 1) {
            let parts = line.components(separatedBy: "\t")
            switch parts.first {
            case "info" where parts.count == 3: snapshot.info[parts[1]] = String(parts[2].prefix(1000))
            case "warning" where parts.count == 2: snapshot.warnings.append(parts[1])
            case "memory" where parts.count == 3:
                snapshot.memoryTotal = number(parts[1]); snapshot.memoryUsed = number(parts[2])
                if let total = snapshot.memoryTotal, let used = snapshot.memoryUsed, used > total { snapshot.memoryUsed = nil }
            case "uptime" where parts.count == 2: snapshot.uptime = number(parts[1])
            case "cpu" where parts.count == 3: snapshot.cpuTotal = number(parts[1]); snapshot.cpuIdle = number(parts[2])
            case "cpuPercent" where parts.count == 2: snapshot.cpuPercent = number(parts[1]).flatMap { $0 <= 100 ? $0 : nil }
            case "process" where parts.count == 8:
                guard let pid = Int(parts[1]), pid > 0, snapshot.processes.count < 2000 else { continue }
                snapshot.processes.append(MonitorProcess(id: pid, user: parts[2], name: parts[6], identity: parts[7], residentBytes: number(parts[3]), cpuSeconds: number(parts[4]), elapsedSeconds: number(parts[5])))
            case "network" where parts.count == 4:
                if let received = number(parts[2]), let sent = number(parts[3]) { snapshot.networks.append(MonitorNetwork(name: parts[1], receivedBytes: received, sentBytes: sent)) }
            case "disk" where parts.count == 5:
                if let total = number(parts[2]), let used = number(parts[3]), let free = number(parts[4]), total > 0, used <= total { snapshot.disks.append(MonitorDisk(mount: parts[1], totalBytes: total, usedBytes: used, availableBytes: free)) }
            case "port" where parts.count == 6:
                if snapshot.ports.count < 4000 { snapshot.ports.append(MonitorPort(transport: parts[1], local: parts[2], remote: parts[3], state: parts[4], pid: Int(parts[5]))) }
            case "portHex" where parts.count == 6:
                if let local = linuxAddress(parts[2]), let remote = linuxAddress(parts[3]), snapshot.ports.count < 4000 {
                    snapshot.ports.append(MonitorPort(transport: parts[1], local: local, remote: remote, state: parts[4], pid: Int(parts[5])))
                }
            default: continue
            }
        }
        snapshot.networks = Dictionary(snapshot.networks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.name < $1.name }
        snapshot.ports = Dictionary(snapshot.ports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.local < $1.local }
        return snapshot
    }

    public static func linuxAddress(_ value: String) -> String? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1], radix: 16), [8, 32].contains(parts[0].count) else { return nil }
        let characters = Array(parts[0]); var bytes: [UInt8] = []
        for offset in stride(from: 0, to: characters.count, by: 8) {
            var word: [UInt8] = []
            for index in stride(from: offset, to: offset + 8, by: 2) {
                guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }; word.append(byte)
            }
            bytes.append(contentsOf: word.reversed())
        }
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") + ":\(port)" }
        let groups = stride(from: 0, to: bytes.count, by: 2).map { String(format: "%x", UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])) }
        return "[" + groups.joined(separator: ":") + "]:\(port)"
    }

    public mutating func measure(since previous: Self?) {
        guard let previous, previous.platform == platform else { return }
        let elapsed = date.timeIntervalSince(previous.date)
        guard elapsed > 0, elapsed < 60, uptime == nil || previous.uptime == nil || uptime! >= previous.uptime! else { return }
        if let total = cpuTotal, let idle = cpuIdle, let oldTotal = previous.cpuTotal, let oldIdle = previous.cpuIdle,
           total > oldTotal, idle >= oldIdle, idle - oldIdle <= total - oldTotal {
            cpuPercent = (1 - (idle - oldIdle) / (total - oldTotal)) * 100
        }
        let oldProcesses = Dictionary(previous.processes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in processes.indices {
            let process = processes[index]
            if let old = oldProcesses[process.id], !process.identity.isEmpty, process.identity == old.identity,
               let cpu = process.cpuSeconds, let oldCPU = old.cpuSeconds, cpu >= oldCPU { processes[index].cpuPercent = (cpu - oldCPU) / elapsed * 100 }
        }
        let oldNetworks = Dictionary(previous.networks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in networks.indices {
            if let old = oldNetworks[networks[index].id], networks[index].receivedBytes >= old.receivedBytes, networks[index].sentBytes >= old.sentBytes {
                networks[index].receiveRate = (networks[index].receivedBytes - old.receivedBytes) / elapsed
                networks[index].sendRate = (networks[index].sentBytes - old.sentBytes) / elapsed
            }
        }
    }
}

public enum AttachmentInsertionPolicy: String, Codable, CaseIterable, Sendable {
    case inherit, automatic, manual
    public func automatic(defaultValue: Bool) -> Bool { self == .inherit ? defaultValue : self == .automatic }
    public var title: String {
        switch self { case .inherit: return L10n.text("跟随全局设置"); case .automatic: return L10n.text("上传后自动插入"); case .manual: return L10n.text("上传后手动插入") }
    }
}
