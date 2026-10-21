import Foundation

public enum CodingAgent: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, pi
    public var id: String { rawValue }
    public var title: String { switch self { case .claude: return "Claude Code"; case .codex: return "Codex"; case .pi: return "Pi" } }
}

public struct AgentSessionRecord: Codable, Identifiable, Equatable, Sendable {
    public let tool: CodingAgent
    public let sessionID: String
    public let directory: String
    public let file: String
    public let dataRoot: String
    public let modified: Double
    public let title: String
    public var id: String { tool.rawValue + ":" + dataRoot + ":" + sessionID }
    public func validate() throws {
        guard UUID(uuidString: sessionID) != nil, Self.validPath(directory), Self.validPath(file), Self.validPath(dataRoot), file.hasSuffix(".jsonl"),
              modified.isFinite, modified >= 0, title.count <= 300, title.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WorkbenchError.message(L10n.text("会话记录无效或不兼容，未启动恢复。"))
        }
    }
    public static func validPath(_ path: String) -> Bool { path.hasPrefix("/") && path.utf8.count <= 8192 && path.rangeOfCharacter(from: .controlCharacters) == nil }
}

public struct AgentToolCapability: Codable, Identifiable, Sendable {
    public let tool: CodingAgent
    public let executable: String?
    public var id: String { tool.rawValue }
    public init(tool: CodingAgent, executable: String?) { self.tool = tool; self.executable = executable }
}

public struct AgentSessionListing: Codable, Sendable {
    public let home: String
    public let user: String
    public let tools: [AgentToolCapability]
    public let sessions: [AgentSessionRecord]
    public let notices: [String]
    public let truncated: Bool
    public init(home: String, user: String, tools: [AgentToolCapability], sessions: [AgentSessionRecord], notices: [String], truncated: Bool) {
        self.home = home; self.user = user; self.tools = tools; self.sessions = sessions; self.notices = notices; self.truncated = truncated
    }
}

public enum AgentLaunchAction: Equatable, Sendable { case newSession, picker, resume(AgentSessionRecord), shell }

public struct AgentLaunchPlan: Equatable, Sendable {
    public let tool: CodingAgent
    public let directory: String
    public let executable: String
    public let arguments: [String]
    public let record: AgentSessionRecord?
    public let isShell: Bool
    public init(tool: CodingAgent, directory: String, executable: String, action: AgentLaunchAction) throws {
        guard AgentSessionRecord.validPath(directory), AgentSessionRecord.validPath(executable) else {
            throw WorkbenchError.message(L10n.text("工作目录或工具路径无效。"))
        }
        self.tool = tool; self.directory = directory; self.executable = executable; isShell = action == .shell
        var arguments: [String] = []
        var record: AgentSessionRecord?
        switch action {
        case .newSession, .shell: break
        case .picker: arguments = tool == .codex ? ["resume"] : ["--resume"]
        case .resume(let selected):
            try selected.validate()
            guard selected.tool == tool, selected.directory == directory else { throw WorkbenchError.message(L10n.text("会话与目标工作目录不一致，未启动恢复。")) }
            record = selected
            switch tool {
            case .claude: arguments = ["--resume", selected.sessionID]
            case .codex: arguments = ["resume", selected.sessionID, "--cd", directory]
            case .pi: arguments = ["--session", selected.file]
            }
        }
        self.arguments = arguments; self.record = record
    }
    public var command: String {
        let prefix = "cd -- " + RemotePath.quote(directory) + " && "
        if isShell { return prefix + "exec \"${SHELL:-/bin/sh}\" -l" }
        let exists = record.map { "test -r " + RemotePath.quote($0.file) + " && " } ?? ""
        let configuration: String
        if let record {
            let key: String
            let root: String
            switch tool {
            case .claude: key = "CLAUDE_CONFIG_DIR"; root = (record.dataRoot as NSString).deletingLastPathComponent
            case .codex: key = "CODEX_HOME"; root = (record.dataRoot as NSString).deletingLastPathComponent
            case .pi: key = "PI_CODING_AGENT_SESSION_DIR"; root = record.dataRoot
            }
            configuration = "export " + key + "=" + RemotePath.quote(root) + " && "
        } else { configuration = "" }
        return prefix + exists + configuration + "exec " + ([executable] + arguments).map(RemotePath.quote).joined(separator: " ")
    }
}
