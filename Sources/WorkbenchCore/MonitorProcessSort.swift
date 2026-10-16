import Foundation

public enum MonitorProcessColumn: String, CaseIterable, Sendable {
    case pid, name, user, cpu, memory, uptime
    public var title: String {
        switch self {
        case .pid: return "PID"
        case .name: return L10n.text("进程")
        case .user: return L10n.text("用户 / UID")
        case .cpu: return "CPU"
        case .memory: return L10n.text("内存")
        case .uptime: return L10n.text("运行时间")
        }
    }
}

public struct MonitorProcessSort: Equatable, Sendable {
    public private(set) var column: MonitorProcessColumn?
    public private(set) var descending = false
    public init() {}
    public mutating func cycle(_ column: MonitorProcessColumn) {
        if self.column != column { self.column = column; descending = false }
        else if !descending { descending = true }
        else { self = Self() }
    }
    public var description: String {
        column.map { "\($0.title) · \(descending ? L10n.text("降序") : L10n.text("升序"))" } ?? L10n.text("默认 · CPU 降序")
    }
    public var comparator: MonitorProcessComparator { MonitorProcessComparator(column: column ?? .cpu, order: column == nil || descending ? .reverse : .forward) }
    public func sorted(_ processes: [MonitorProcess]) -> [MonitorProcess] { processes.sorted(using: comparator) }
}

public struct MonitorProcessComparator: SortComparator, Sendable {
    public let column: MonitorProcessColumn
    public var order: SortOrder
    public init(column: MonitorProcessColumn, order: SortOrder = .forward) { self.column = column; self.order = order }
    public func compare(_ left: MonitorProcess, _ right: MonitorProcess) -> ComparisonResult {
        let result: ComparisonResult
        switch column {
        case .pid: result = number(Double(left.id), Double(right.id))
        case .cpu: result = number(left.cpuPercent, right.cpuPercent)
        case .memory: result = number(left.residentBytes, right.residentBytes)
        case .uptime: result = number(left.elapsedSeconds, right.elapsedSeconds)
        case .name: result = text(left.name, right.name)
        case .user: result = text(left.user, right.user)
        }
        if result != .orderedSame { return result }
        return left.id < right.id ? .orderedAscending : (left.id > right.id ? .orderedDescending : .orderedSame)
    }
    private func direction(_ result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }
        return result == .orderedAscending ? .orderedDescending : (result == .orderedDescending ? .orderedAscending : .orderedSame)
    }
    private func number(_ left: Double?, _ right: Double?) -> ComparisonResult {
        let left = left.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let right = right.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        switch (left, right) {
        case let (.some(left), .some(right)): return direction(left < right ? .orderedAscending : (left > right ? .orderedDescending : .orderedSame))
        case (.some, .none): return .orderedAscending
        case (.none, .some): return .orderedDescending
        case (.none, .none): return .orderedSame
        }
    }
    private func text(_ left: String, _ right: String) -> ComparisonResult {
        if left.isEmpty != right.isEmpty { return left.isEmpty ? .orderedDescending : .orderedAscending }
        return direction(left.localizedStandardCompare(right))
    }
}
