import Foundation

public struct SavedTerminal: Codable, Equatable, Identifiable {
    public var id: UUID
    public var hostID: UUID?
    public var connectionKey: String?
    public var tmuxID: String?
    public init(id: UUID, hostID: UUID?, connectionKey: String?, tmuxID: String?) {
        self.id = id; self.hostID = hostID; self.connectionKey = connectionKey; self.tmuxID = tmuxID
    }
}

public struct WorkspaceSnapshot: Codable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var updated: Date
    public var terminals: [SavedTerminal]
    public var layout: TerminalLayout
    public init(id: UUID, title: String, terminals: [SavedTerminal], layout: TerminalLayout) {
        self.id = id; self.title = title; updated = Date(); self.terminals = terminals; self.layout = layout
    }
    public func validate() throws {
        let identifiers = terminals.map(\.id)
        let leaves = layout.tabs.flatMap(\.terminals)
        guard Set(identifiers).count == identifiers.count,
              Set(leaves).count == leaves.count, Set(leaves) == Set(identifiers),
              Set(layout.tabs.map(\.id)).count == layout.tabs.count,
              layout.tabs.allSatisfy({ $0.terminals.contains($0.focused) && validPane($0.root) }),
              layout.tabs.isEmpty ? layout.selectedTabID == nil : layout.tabs.contains(where: { $0.id == layout.selectedTabID }) else {
            throw WorkbenchError.message(L10n.text("保存的工作区布局无效，未启动任何连接。"))
        }
    }
    private func validPane(_ node: TerminalPaneNode) -> Bool {
        switch node {
        case .terminal: return true
        case .split(_, _, let ratio, let first, let second): return ratio.isFinite && (0.05...0.95).contains(ratio) && validPane(first) && validPane(second)
        }
    }
}

public struct CommandSnippet: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var command: String
    public var tags: String
    public var hostID: UUID?
    public init(id: UUID = UUID(), name: String = "", command: String = "", tags: String = "", hostID: UUID? = nil) {
        self.id = id; self.name = name; self.command = command; self.tags = tags; self.hostID = hostID
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              !command.trimmingCharacters(in: .whitespaces).isEmpty, command.utf8.count <= 16384,
              command.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw WorkbenchError.message(L10n.text("请输入名称和单行命令；不允许换行或控制字符，也不会自动回车。"))
        }
    }
}

public struct DirectoryBookmark: Codable, Equatable, Identifiable {
    public var id: UUID
    public var hostID: UUID?
    public var connectionKey: String?
    public var path: String
    public init(hostID: UUID?, connectionKey: String?, path: String) {
        id = UUID(); self.hostID = hostID; self.connectionKey = connectionKey; self.path = path
    }
}

public enum TerminalDirectory {
    public static func path(from report: String?, allowedHosts: Set<String>) -> String? {
        guard let report, report.utf8.count <= 16384, let url = URLComponents(string: report),
              url.scheme?.lowercased() == "file", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil, let authority = url.host,
              allowedHosts.map({ $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }).contains(authority.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))),
              let path = url.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/"), path.utf8.count <= 4096,
              path.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else { return nil }
        return path
    }
}

public struct WorkspaceToolsState: Codable {
    public var workspaces: [WorkspaceSnapshot] = []
    public var snippets: [CommandSnippet] = []
    public var bookmarks: [DirectoryBookmark] = []
    public init() {}
}
