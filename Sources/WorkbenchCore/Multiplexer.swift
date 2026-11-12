import Foundation

/// 终端多路复用器种类。tmux 走原有 `TmuxService`；Zellij 与 herdr 只做会话层与复制（0.1.24）。
public enum MultiplexerKind: String, Codable, CaseIterable, Hashable, Sendable {
    case tmux, zellij, herdr
    public var title: String {
        switch self { case .tmux: return "tmux"; case .zellij: return "Zellij"; case .herdr: return "herdr" }
    }
    public var executableName: String { rawValue }
    /// 支持的最低版本（主、次版本）。低于此版本时界面禁用操作并提示。
    public var minimumVersion: (Int, Int) {
        switch self { case .tmux: return (0, 0); case .zellij: return (0, 44); case .herdr: return (0, 9) }
    }
    public var canRename: Bool { self != .herdr }

    /// Zellij/herdr 会话名称：限 ASCII 字母、数字、`.`、`_`、`-`，1–64 个字符，避免 Shell、Socket 路径与工具自身校验差异。
    public func validateSessionName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("-"), !name.hasPrefix("."),
              name.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0) }) else {
            throw WorkbenchError.message(L10n.text("\(title) 会话名称限 1–64 个英文字母、数字、点、下划线或连字符，且不能以点或连字符开头。"))
        }
    }

    /// 从 `zellij --version`、`herdr 0.9.5` 一类输出中解析主、次版本。
    public static func parseVersion(_ text: String) -> (Int, Int)? {
        guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first(where: { $0.first?.isNumber == true }) else { return nil }
        let parts = token.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1].prefix(while: \.isNumber)) ?? 0 : 0
        return (major, minor)
    }
    public func supports(version: (Int, Int)) -> Bool {
        version.0 > minimumVersion.0 || (version.0 == minimumVersion.0 && version.1 >= minimumVersion.1)
    }
}

/// Zellij/herdr 会话。`name` 即进入、重命名与结束时使用的标识。
public struct MultiplexerSession: Identifiable, Hashable, Sendable {
    public var kind: MultiplexerKind
    public var name: String
    /// false 表示已退出（Zellij EXITED、herdr stopped），只能删除。
    public var running: Bool
    public var id: String { kind.rawValue + ":" + name }
    public init(kind: MultiplexerKind, name: String, running: Bool) { self.kind = kind; self.name = name; self.running = running }
}

/// Zellij 标签或 herdr 工作区/标签中的一个终端窗格。
public struct MultiplexerPane: Identifiable, Hashable, Sendable {
    public var id: String
    public var session: String
    /// 所在分组：Zellij 标签名，herdr “工作区 · 标签”。
    public var group: String
    public var command: String
    public var directory: String
    public var focused: Bool
    /// herdr 识别到的 Agent 及其状态，例如 claude / working。
    public var agent: String?
    public var agentStatus: String?
    public init(id: String, session: String, group: String, command: String, directory: String, focused: Bool, agent: String? = nil, agentStatus: String? = nil) {
        self.id = id; self.session = session; self.group = group; self.command = command; self.directory = directory
        self.focused = focused; self.agent = agent; self.agentStatus = agentStatus
    }
}

/// 终端标签附着的 Zellij/herdr 会话。tmux 仍使用 `tmuxID`，两者互斥。
public struct MultiplexerAttachment: Codable, Hashable, Sendable {
    public var kind: MultiplexerKind
    public var session: String
    /// true 表示会话不存在时由工具在终端内创建（herdr 没有可靠的后台创建方式）。
    public var create: Bool
    public init(kind: MultiplexerKind, session: String, create: Bool = false) { self.kind = kind; self.session = session; self.create = create }
}

/// 解析 Zellij 与 herdr 的命令输出；纯函数，便于离线断言。
public enum MultiplexerParsing {
    /// `zellij ls -n`：每行 `名 [Created …] (EXITED - attach to resurrect)` 或 `(current)`。
    public static func zellijSessions(_ output: String) -> [MultiplexerSession] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw).replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard let marker = line.range(of: " [Created ", options: .backwards) else { return nil }
            let name = String(line[..<marker.lowerBound])
            guard !name.isEmpty, !name.hasPrefix("No ") else { return nil }
            return MultiplexerSession(kind: .zellij, name: name, running: !line[marker.upperBound...].contains("EXITED"))
        }
    }
    /// `zellij action list-panes --json`：过滤插件与已退出窗格。
    public static func zellijPanes(_ output: String, session: String) -> [MultiplexerPane] {
        guard let data = output.data(using: .utf8), let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard item["is_plugin"] as? Bool == false, item["exited"] as? Bool != true, let identifier = item["id"] as? Int else { return nil }
            let command = (item["pane_command"] as? String) ?? (item["terminal_command"] as? String) ?? (item["title"] as? String) ?? ""
            return MultiplexerPane(id: "terminal_\(identifier)", session: session, group: item["tab_name"] as? String ?? "",
                                   command: (command as NSString).lastPathComponent, directory: item["pane_cwd"] as? String ?? "",
                                   focused: item["is_focused"] as? Bool == true)
        }
    }
    /// `herdr session list --json`。
    public static func herdrSessions(_ output: String) -> [MultiplexerSession] {
        guard let data = output.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [[String: Any]] else { return [] }
        return sessions.compactMap { item in
            guard let name = item["name"] as? String, (try? MultiplexerKind.herdr.validateSessionName(name)) != nil else { return nil }
            return MultiplexerSession(kind: .herdr, name: name, running: item["running"] as? Bool ?? false)
        }
    }
    /// herdr 的 `workspace list` 与 `pane list`；`server_not_running` 等错误返回 nil。
    public static func herdrPanes(workspaces: String, panes: String, session: String) -> [MultiplexerPane]? {
        func result(_ text: String) -> [String: Any]? {
            guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return root["result"] as? [String: Any]
        }
        guard let paneItems = result(panes)?["panes"] as? [[String: Any]] else { return nil }
        let labels = ((result(workspaces)?["workspaces"] as? [[String: Any]]) ?? []).reduce(into: [String: String]()) { map, item in
            if let identifier = item["workspace_id"] as? String { map[identifier] = item["label"] as? String ?? identifier }
        }
        return paneItems.compactMap { item in
            guard let identifier = item["pane_id"] as? String else { return nil }
            let workspace = item["workspace_id"] as? String ?? ""
            let tab = (item["tab_id"] as? String)?.split(separator: ":").last.map(String.init) ?? ""
            let title = (item["terminal_title_stripped"] as? String) ?? (item["terminal_title"] as? String) ?? ""
            return MultiplexerPane(id: identifier, session: session, group: [labels[workspace] ?? workspace, tab].filter { !$0.isEmpty }.joined(separator: " · "),
                                   command: title, directory: (item["foreground_cwd"] as? String) ?? (item["cwd"] as? String) ?? "",
                                   focused: item["focused"] as? Bool == true, agent: item["agent"] as? String, agentStatus: item["agent_status"] as? String)
        }
    }
}
