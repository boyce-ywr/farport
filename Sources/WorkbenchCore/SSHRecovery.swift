import Foundation

public struct TerminalProcessExit: Equatable {
    public let code: Int?
    public let signal: Int?
    public init(waitStatus: Int32?) {
        guard let waitStatus, waitStatus >= 0 else { code = nil; signal = nil; return }
        let low = waitStatus & 0x7f
        if low == 0 { code = Int((waitStatus >> 8) & 0xff); signal = nil }
        else if low != 0x7f { code = nil; signal = Int(low) }
        else { code = nil; signal = nil }
    }
    public var shouldRecoverSSH: Bool { code == 255 || signal != nil || (code == nil && signal == nil) }
}

public struct SSHRetryPolicy {
    public private(set) var failures = 0
    public init() {}
    public mutating func reset() { failures = 0 }
    public mutating func nextDelay(stableDuration: TimeInterval = 0) -> TimeInterval {
        if stableDuration >= 30 { reset() }
        let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        let delay = delays[min(failures, delays.count - 1)]
        failures = min(failures + 1, 1000)
        return delay
    }
    public static func permitsRetry(diagnostic: String) -> Bool {
        let message = diagnostic.lowercased()
        let needsUser = ["permission denied", "authentication failed", "too many authentication", "host key verification failed", "remote host identification has changed", "bad owner", "no matching", "sign_and_send_pubkey", "bad configuration", "bad config"]
        guard !needsUser.contains(where: message.contains) else { return false }
        return ["connection refused", "connection reset", "connection closed", "connection timed out", "timed out", "operation timeout", "no route to host", "network is unreachable", "could not resolve hostname", "broken pipe", "connection aborted", "操作超时"].contains(where: message.contains)
    }
}

public struct ConnectionEvent: Codable {
    public let date: Date
    public let event: String
    public let processID: Int32?
    public let waitStatus: Int32?
    public init(event: String, processID: Int32? = nil, waitStatus: Int32? = nil) {
        date = Date(); self.event = event; self.processID = processID; self.waitStatus = waitStatus
    }
}
