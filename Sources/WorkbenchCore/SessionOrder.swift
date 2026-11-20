import Foundation

/// 会话页的手动排序：按“主机 × 工具”分别记住会话名的顺序。纯函数，便于离线断言。
public enum SessionOrder {
    /// 排序记录的键：主机 ID（此 Mac 为 local）与工具。
    public static func key(hostID: UUID?, kind: MultiplexerKind) -> String { (hostID?.uuidString ?? "local") + "|" + kind.rawValue }

    /// 按已保存的顺序排列：记录中仍存在的会话在前，其余（新会话）按原顺序排在后面。
    public static func apply<T>(_ items: [T], name: (T) -> String, saved: [String]) -> [T] {
        guard !saved.isEmpty else { return items }
        var rank: [String: Int] = [:]
        for (index, value) in saved.enumerated() where rank[value] == nil { rank[value] = index }
        return items.enumerated().sorted { left, right in
            switch (rank[name(left.element)], rank[name(right.element)]) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left.offset < right.offset
            }
        }.map(\.element)
    }

    /// 移动后的完整顺序：current 为当前显示顺序；把 moving 放到 target 的位置（向下拖放到其后，向上拖放到其前）。
    /// 返回只含当前存在会话的新记录，已结束的会话随之移除。
    public static func move(_ moving: String, to target: String, in current: [String]) -> [String] {
        guard moving != target, let from = current.firstIndex(of: moving), let to = current.firstIndex(of: target) else { return current }
        var result = current
        result.remove(at: from)
        result.insert(moving, at: to)
        return result
    }
    public enum Step { case up, down, top }
    public static func move(_ moving: String, _ step: Step, in current: [String]) -> [String] {
        guard let index = current.firstIndex(of: moving) else { return current }
        switch step {
        case .up: return index > 0 ? move(moving, to: current[index - 1], in: current) : current
        case .down: return index + 1 < current.count ? move(moving, to: current[index + 1], in: current) : current
        case .top: return index > 0 ? move(moving, to: current[0], in: current) : current
        }
    }
    /// 会话改名后，顺序记录中的名称随之更新。
    public static func rename(_ old: String, to new: String, in saved: [String]) -> [String] {
        saved.map { $0 == old ? new : $0 }
    }
}
