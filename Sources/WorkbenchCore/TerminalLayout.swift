import Foundation

public enum TerminalSplitAxis: Codable, Equatable { case leftRight, topBottom }

public indirect enum TerminalPaneNode: Codable, Equatable {
    case terminal(UUID)
    case split(id: UUID, axis: TerminalSplitAxis, ratio: Double, first: TerminalPaneNode, second: TerminalPaneNode)

    public var id: UUID {
        switch self { case .terminal(let identifier): return identifier; case .split(let identifier, _, _, _, _): return identifier }
    }
    public var terminals: [UUID] {
        switch self { case .terminal(let identifier): return [identifier]; case .split(_, _, _, let first, let second): return first.terminals + second.terminals }
    }
    fileprivate func inserting(_ newTerminal: UUID, beside target: UUID, axis: TerminalSplitAxis) -> Self {
        switch self {
        case .terminal(let existing):
            return existing == target ? .split(id: UUID(), axis: axis, ratio: 0.5, first: self, second: .terminal(newTerminal)) : self
        case .split(let identifier, let direction, let ratio, let first, let second):
            return .split(id: identifier, axis: direction, ratio: ratio, first: first.inserting(newTerminal, beside: target, axis: axis), second: second.inserting(newTerminal, beside: target, axis: axis))
        }
    }
    fileprivate func removing(_ identifier: UUID) -> Self? {
        switch self {
        case .terminal(let existing): return existing == identifier ? nil : self
        case .split(let splitID, let axis, let ratio, let first, let second):
            let remainingFirst = first.removing(identifier); let remainingSecond = second.removing(identifier)
            if let remainingFirst, let remainingSecond { return .split(id: splitID, axis: axis, ratio: ratio, first: remainingFirst, second: remainingSecond) }
            return remainingFirst ?? remainingSecond
        }
    }
    fileprivate func resizing(_ identifier: UUID, ratio newRatio: Double) -> Self {
        switch self {
        case .terminal: return self
        case .split(let splitID, let axis, let ratio, let first, let second):
            return .split(id: splitID, axis: axis, ratio: splitID == identifier ? newRatio : ratio, first: first.resizing(identifier, ratio: newRatio), second: second.resizing(identifier, ratio: newRatio))
        }
    }
}

public struct TerminalTab: Codable, Equatable, Identifiable {
    public let id: UUID
    public fileprivate(set) var root: TerminalPaneNode
    public fileprivate(set) var focused: UUID
    public fileprivate(set) var zoomed = false
    public var terminals: [UUID] { root.terminals }
}

public struct TerminalLayout: Codable, Equatable {
    public private(set) var tabs: [TerminalTab] = []
    public private(set) var selectedTabID: UUID?
    public init() {}
    public var selectedTab: TerminalTab? { tabs.first { $0.id == selectedTabID } }
    public var primary: UUID? { selectedTab?.terminals.first }
    public var secondary: UUID? { selectedTab?.terminals.dropFirst().first }
    public var focused: UUID? { selectedTab?.focused }
    public func tab(containing identifier: UUID) -> TerminalTab? { tabs.first { $0.terminals.contains(identifier) } }

    public mutating func select(_ identifier: UUID) {
        if let index = tabs.firstIndex(where: { $0.terminals.contains(identifier) }) {
            selectedTabID = tabs[index].id; tabs[index].focused = identifier
        } else {
            tabs.append(TerminalTab(id: identifier, root: .terminal(identifier), focused: identifier)); selectedTabID = identifier
        }
    }
    public mutating func selectTab(_ identifier: UUID) {
        if tabs.contains(where: { $0.id == identifier }) { selectedTabID = identifier }
    }
    public mutating func moveTab(_ identifier: UUID, before target: UUID?) {
        guard identifier != target, let source = tabs.firstIndex(where: { $0.id == identifier }),
              target == nil || tabs.contains(where: { $0.id == target }) else { return }
        let tab = tabs.remove(at: source)
        let destination = target.flatMap { identifier in tabs.firstIndex { $0.id == identifier } } ?? tabs.endIndex
        tabs.insert(tab, at: destination)
    }
    public mutating func split(with identifier: UUID, axis: TerminalSplitAxis = .leftRight) {
        guard tab(containing: identifier) == nil else { select(identifier); return }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { select(identifier); return }
        tabs[index].root = tabs[index].root.inserting(identifier, beside: tabs[index].focused, axis: axis)
        tabs[index].focused = identifier; tabs[index].zoomed = false
    }
    public mutating func toggleZoom() {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs[index].terminals.count > 1 else { return }
        tabs[index].zoomed.toggle()
    }
    public mutating func resize(_ identifier: UUID, ratio: Double) {
        guard ratio.isFinite else { return }
        for index in tabs.indices { tabs[index].root = tabs[index].root.resizing(identifier, ratio: min(0.95, max(0.05, ratio))) }
    }
    public mutating func focusNext(backward: Bool = false) {
        guard let tab = selectedTab, let index = tab.terminals.firstIndex(of: tab.focused) else { return }
        select(tab.terminals[(index + (backward ? tab.terminals.count - 1 : 1)) % tab.terminals.count])
    }
    public mutating func selectNextTab(backward: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(index + (backward ? tabs.count - 1 : 1)) % tabs.count].id
    }
    public mutating func close(_ identifier: UUID, fallback: UUID? = nil) {
        guard let index = tabs.firstIndex(where: { $0.terminals.contains(identifier) }) else { return }
        if let root = tabs[index].root.removing(identifier) {
            tabs[index].root = root
            if tabs[index].focused == identifier { tabs[index].focused = root.terminals[0] }
            if root.terminals.count == 1 { tabs[index].zoomed = false }
        } else {
            let removed = tabs.remove(at: index)
            if selectedTabID == removed.id { selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        }
    }
}
