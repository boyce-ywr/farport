import Foundation
import Darwin
import WorkbenchCore

public struct LocalDockerTerminal: Equatable, Sendable {
    public let target: TmuxTarget
    public let foregroundPID: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public let executable: String
    public let invocation: DockerTerminalCommand
    public let environment: [String: String]
}

extension TmuxService {
    public func localDockerTerminal(session: String) throws -> LocalDockerTerminal {
        func unavailable() -> Error { WorkbenchError.message(L10n.text("无法确认原 tmux 窗格的 Docker 进程，未发送附件。")) }
        guard host == nil else { throw unavailable() }
        let target = try attachmentTarget(session: session)
        guard target.command == "docker" else { throw unavailable() }
        guard let panePID = Int32(target.processID), panePID > 0 else { throw unavailable() }
        func foreground() throws -> Int32 {
            var pane = proc_bsdinfo()
            guard proc_pidinfo(panePID, PROC_PIDTBSDINFO, 0, &pane, Int32(MemoryLayout.size(ofValue: pane))) == MemoryLayout.size(ofValue: pane),
                  pane.pbi_uid == getuid() else { throw unavailable() }
            return Int32(bitPattern: pane.e_tpgid)
        }
        let identifier = try foreground()
        guard identifier > 0 else { throw unavailable() }
        var info = proc_bsdinfo()
        guard proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info), info.pbi_uid == getuid() else { throw unavailable() }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(identifier, &path, UInt32(path.count)) > 0 else { throw unavailable() }
        let executable = String(cString: path)
        guard (executable as NSString).lastPathComponent == "docker" else { throw unavailable() }
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, identifier]
        var length = 0
        guard sysctl(&query, UInt32(query.count), nil, &length, nil, 0) == 0, length > 4, length <= 1024 * 1024 else { throw unavailable() }
        var data = [UInt8](repeating: 0, count: length)
        guard sysctl(&query, UInt32(query.count), &data, &length, nil, 0) == 0 else { throw unavailable() }
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 1024 else { throw unavailable() }
        var position = 4
        while position < length && data[position] != 0 { position += 1 }
        while position < length && data[position] == 0 { position += 1 }
        func next() throws -> String {
            let start = position
            while position < length && data[position] != 0 { position += 1 }
            guard position < length, let value = String(bytes: data[start..<position], encoding: .utf8) else { throw unavailable() }
            position += 1; return value
        }
        var arguments: [String] = []
        for _ in 0..<count { arguments.append(try next()) }
        var environment: [String: String] = [:]
        while position < length && data[position] != 0 {
            let value = try next()
            guard let separator = value.firstIndex(of: "=") else { continue }
            let key = String(value[..<separator])
            if ["DOCKER_CONTEXT", "DOCKER_HOST", "DOCKER_CONFIG"].contains(key) { environment[key] = String(value[value.index(after: separator)...]) }
        }
        var finalInfo = proc_bsdinfo()
        guard try attachmentTarget(session: session) == target, try foreground() == identifier,
              proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, &finalInfo, Int32(MemoryLayout.size(ofValue: finalInfo))) == MemoryLayout.size(ofValue: finalInfo),
              finalInfo.pbi_uid == info.pbi_uid, finalInfo.pbi_start_tvsec == info.pbi_start_tvsec, finalInfo.pbi_start_tvusec == info.pbi_start_tvusec else { throw unavailable() }
        return LocalDockerTerminal(target: target, foregroundPID: identifier, startedSeconds: info.pbi_start_tvsec,
                                   startedMicroseconds: info.pbi_start_tvusec, executable: executable,
                                   invocation: try DockerTerminalCommand(arguments: arguments), environment: environment)
    }
}
