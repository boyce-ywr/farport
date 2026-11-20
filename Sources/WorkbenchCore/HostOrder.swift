import Foundation

/// 侧栏主机的手动排序：只在同一分组内移动，其他分组的主机位置不变。纯函数，便于离线断言。
public enum HostOrder {
    /// 把 id 放到同组 target 的位置（向下放到其后，向上放到其前）；不同分组或不存在时不变。
    public static func move(_ id: UUID, to target: UUID, in hosts: [HostProfile]) -> [HostProfile] {
        guard id != target, let from = hosts.firstIndex(where: { $0.id == id }), let to = hosts.firstIndex(where: { $0.id == target }),
              hosts[from].group == hosts[to].group else { return hosts }
        var result = hosts
        let moving = result.remove(at: from)
        result.insert(moving, at: to)
        return result
    }
    public static func move(_ id: UUID, _ step: SessionOrder.Step, in hosts: [HostProfile]) -> [HostProfile] {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return hosts }
        let peers = hosts.filter { $0.group == hosts[index].group }.map(\.id)
        guard let position = peers.firstIndex(of: id) else { return hosts }
        switch step {
        case .up: return position > 0 ? move(id, to: peers[position - 1], in: hosts) : hosts
        case .down: return position + 1 < peers.count ? move(id, to: peers[position + 1], in: hosts) : hosts
        case .top: return position > 0 ? move(id, to: peers[0], in: hosts) : hosts
        }
    }
}
