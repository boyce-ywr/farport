import AppKit
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum TerminalSplitDirectoryChecks {
    static func run(workspace: Workspace) async throws {
        let root = workspace.store.paths.root.appendingPathComponent("split-directory")
        let firstDirectory = root.appendingPathComponent("Projects 中文 ' $; one")
        let secondDirectory = root.appendingPathComponent("Other Projects")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        defer { workspace.sessions.forEach { $0.close() } }
        workspace.connectLocal()
        guard let first = workspace.selectedTerminal else { throw WorkbenchError.message("没有源终端") }
        try await wait { first.connected }
        let sourceInput = root.appendingPathComponent("source-input")
        first.terminal.send(txt: "cd -- \(RemotePath.quote(firstDirectory.path)); stty -echo -icanon; : > \(RemotePath.quote(sourceInput.path)); printf '\\nSPLIT_DIRECTORY_READY\\n'; cat >> \(RemotePath.quote(sourceInput.path))\n")
        try await wait { hasLine("SPLIT_DIRECTORY_READY", in: first) }
        workspace.connectLocal()
        guard let other = workspace.selectedTerminal else { throw WorkbenchError.message("没有第二终端") }
        try await wait { other.connected }
        other.terminal.send(txt: "cd -- \(RemotePath.quote(secondDirectory.path)); printf '\\nSECOND_DIRECTORY_READY\\n'\n")
        try await wait { hasLine("SECOND_DIRECTORY_READY", in: other) }
        let parentDirectory = FileManager.default.currentDirectoryPath
        workspace.selectTerminal(first)
        workspace.newTerminal(split: true, axis: .topBottom)
        guard let split = workspace.selectedTerminal, split !== first else { throw WorkbenchError.message("分屏未创建新终端") }
        workspace.selectTerminal(other)
        try await verifyDirectory(split, expected: firstDirectory, file: root.appendingPathComponent("split-first-result"))
        guard try Data(contentsOf: sourceInput).isEmpty else { throw WorkbenchError.message("分屏向源终端注入了cd或其他输入") }
        workspace.selectTerminal(other)
        workspace.newTerminal(split: true)
        guard let secondSplit = workspace.selectedTerminal else { throw WorkbenchError.message("没有第二分屏") }
        try await verifyDirectory(secondSplit, expected: secondDirectory, file: root.appendingPathComponent("split-second-result"))
        workspace.newTerminal()
        guard let fresh = workspace.selectedTerminal else { throw WorkbenchError.message("没有新标签") }
        try await verifyDirectory(fresh, expected: FileManager.default.homeDirectoryForCurrentUser, file: root.appendingPathComponent("new-tab-result"))
        guard FileManager.default.currentDirectoryPath == parentDirectory else { throw WorkbenchError.message("分屏改变了应用全局cwd") }
        for host in [nil as HostProfile?] + workspace.store.hosts.filter({ $0.address == "127.0.0.1" && [22281, 22282].contains($0.port) }).map(Optional.some) {
            let service = TmuxService(transport: workspace.store.transport, host: host)
            let name = "farport-split-cwd-" + UUID().uuidString
            let location = host == nil ? firstDirectory.path : "/tmp/" + name + " quote ' 空格"
            let client = try workspace.store.transport.files(host)
            if host != nil { try client.mkdir(location) }
            defer {
                try? service.kill(session: name)
                if host != nil { try? client.removeRecursively(location) }
                client.close()
            }
            _ = try service.execute("new-session -d -s \(RemotePath.quote(name)) -c \(RemotePath.quote(location)) 'sleep 120'").checked()
            guard let tmux = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("未创建目录测试tmux") }
            workspace.attachTmux(host, session: tmux)
            guard let original = workspace.selectedTerminal else { throw WorkbenchError.message("未附着目录测试tmux") }
            try await wait { original.connected }
            workspace.newTerminal(split: true, axis: .topBottom)
            guard let child = workspace.selectedTerminal, child !== original else { throw WorkbenchError.message("没有从tmux分屏") }
            try await wait { child.connected }
            let resultPath = RemotePath.join(location, "cwd-result")
            let donePath = resultPath + ".done"
            child.terminal.send(txt: "/bin/pwd -P > \(RemotePath.quote(resultPath)); printf done > \(RemotePath.quote(donePath))\n")
            try await wait { (try? client.stat(donePath)) != nil }
            let actual = String(decoding: try client.preview(resultPath), as: UTF8.self).trimmingCharacters(in: .newlines)
            let expected = try client.realpath(location)
            guard actual == expected else { throw WorkbenchError.message("tmux来源分屏目录不符：\(actual)，预期\(expected)") }
            guard try service.target(session: tmux.id).directory == actual else { throw WorkbenchError.message("分屏改变了原tmux目录") }
            workspace.close(child); workspace.close(original)
        }
        print("PASS · 本机左右/上下分屏继承发起窗格真实cwd、切换焦点不串台、源进程零输入、新标签仍为主目录")
        print("PASS · 本机及隔离SSH tmux来源分屏继承工作目录，原tmux进程与目录保持")
        fflush(stdout)
    }
    private static func verifyDirectory(_ session: TerminalSession, expected: URL, file: URL) async throws {
        try await wait { session.connected }
        let done = file.appendingPathExtension("done")
        session.terminal.send(txt: "/bin/pwd -P > \(RemotePath.quote(file.path)); printf ok > \(RemotePath.quote(done.path))\n")
        try await wait { FileManager.default.fileExists(atPath: done.path) }
        let actual = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .newlines)
        let canonical = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "cd -- \(RemotePath.quote(expected.path)) && /bin/pwd -P"]).checked().text.trimmingCharacters(in: .newlines)
        guard actual == canonical else { throw WorkbenchError.message("分屏目录错误：实际 \(actual)，预期 \(canonical)") }
    }
    private static func hasLine(_ text: String, in session: TerminalSession) -> Bool {
        let terminal = session.terminal.getTerminal()
        return (0..<terminal.rows).contains { terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).trimmingCharacters(in: .whitespacesAndNewlines) == text }
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("分屏目录回归超时：\(line)") }; try await Task.sleep(for: .milliseconds(70)) }
    }
}
