import AppKit
import SwiftUI
import WorkbenchCore

@MainActor
enum AgentListChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let root = workspace.store.paths.root.appendingPathComponent("history-fixture")
        let configurations = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent(".claude").path,
                              "CODEX_HOME": root.appendingPathComponent(".codex").path,
                              "PI_CODING_AGENT_DIR": root.appendingPathComponent(".pi/agent").path,
                              "PI_CODING_AGENT_SESSION_DIR": root.appendingPathComponent(".pi/agent/sessions").path]
        var saved: [String: String] = [:]
        var absent: Set<String> = []
        for (key, value) in configurations {
            if let old = getenv(key) { saved[key] = String(cString: old) } else { absent.insert(key) }
            setenv(key, value, 1)
        }
        defer {
            for key in configurations.keys { if absent.contains(key) { unsetenv(key) } else { setenv(key, saved[key]!, 1) } }
            workspace.sessions.forEach { $0.close() }
        }
        for tool in CodingAgent.allCases {
            for index in 0..<3 {
                let id = UUID().uuidString.lowercased()
                let directory = root.appendingPathComponent("project-\(index)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let container: URL
                switch tool {
                case .claude: container = root.appendingPathComponent(".claude/projects/\(index)")
                case .codex: container = root.appendingPathComponent(".codex/sessions/2026/10/\(index)")
                case .pi: container = root.appendingPathComponent(".pi/agent/sessions/\(index)")
                }
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
                let stamp = "2026-10-\(18 + index)T12:00:00Z"
                let title = "\(tool.title) 工作会话 \(index)"
                var rows: [[String: Any]]
                switch tool {
                case .claude:
                    rows = [["type": "user", "sessionId": id, "cwd": directory.path, "timestamp": stamp], ["type": "custom-title", "sessionId": id, "customTitle": title]]
                case .codex:
                    rows = [["type": "session_meta", "timestamp": stamp, "payload": ["id": id, "cwd": directory.path, "name": title]]]
                case .pi:
                    rows = [["type": "session", "version": 3, "id": id, "cwd": directory.path, "timestamp": stamp], ["type": "session_info", "name": title, "timestamp": stamp]]
                }
                rows.append(["type": "message", "timestamp": stamp, "private": "not-returned"])
                var data = Data()
                for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
                try data.write(to: container.appendingPathComponent(id + ".jsonl"))
            }
        }
        workspace.connectLocal()
        guard let source = workspace.selectedTerminal else { throw WorkbenchError.message("没有列表测试源终端") }
        let deadline = Date().addingTimeInterval(15)
        while !source.connected { guard Date() < deadline else { throw WorkbenchError.message("源终端未启动") }; try await Task.sleep(for: .milliseconds(70)) }
        let model = AgentSessionsModel(workspace: workspace)
        for tool in CodingAgent.allCases {
            model.tool = tool; await model.refresh()
            guard model.failure == nil, model.records.count == 3,
                  model.records.allSatisfy({ $0.tool == tool && !$0.title.isEmpty && $0.sessionID.count == 36 }),
                  model.records[0].directory.hasSuffix("project-2"), model.records[2].directory.hasSuffix("project-0") else {
                throw WorkbenchError.message(model.failure ?? "Agent切换未自动读取全部目录或排序/名称/ID错误")
            }
            let records = model.records
            model.directory = root.appendingPathComponent("project-0").path
            guard model.records == records else { throw WorkbenchError.message("启动目录仍影响会话筛选或排序") }
        }
        workspace.showAgentSessions = true
        try await Task.sleep(for: .seconds(2))
        if let content = source.terminal.window?.attachedSheet?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        workspace.showAgentSessions = false; model.stop()
        try await Task.sleep(for: .milliseconds(300))
        print("PASS · 三Agent自动扫描全部项目、完整ID/名称/路径/活跃时间、切换工具和启动目录不影响倒序列表；非前台模型检查")
        fflush(stdout)
    }
}
