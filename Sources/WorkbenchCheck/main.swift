import Foundation
import Darwin
import Security
import WorkbenchCore
import OpenSSHBackend

signal(SIGPIPE, SIG_IGN)
setbuf(stdout, nil)
let arguments = Array(CommandLine.arguments.dropFirst())
let root = URL(fileURLWithPath: arguments.first ?? ".test/app").standardizedFileURL
let stress = arguments.contains("--stress")
var results: [[String: String]] = []
var recordedJobs: [TransferJob] = []

final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []
    private var values: [TransferJob] = []
    func failure(_ message: String) { lock.lock(); failures.append(message); lock.unlock() }
    func job(_ value: TransferJob) { lock.lock(); values.append(value); lock.unlock() }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return failures }
    var jobs: [TransferJob] { lock.lock(); defer { lock.unlock() }; return values }
}

func require(_ value: @autoclosure () throws -> Bool, _ detail: String) throws {
    if try !value() { throw WorkbenchError.message(detail) }
}
func check(_ name: String, _ operation: () throws -> Void) throws {
    let start = Date(); print("RUN  \(name)")
    do { try operation(); let elapsed = String(format: "%.2f", Date().timeIntervalSince(start)); print("PASS \(name) [\(elapsed)s]"); results.append(["name": name, "status": "passed", "seconds": elapsed]) }
    catch { print("FAIL \(name): \(error.localizedDescription)"); results.append(["name": name, "status": "failed", "error": error.localizedDescription]); throw error }
}
func randomData(_ count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    guard status == errSecSuccess else { throw WorkbenchError.message("无法生成随机测试数据") }; return data
}

do {
    let paths = try ApplicationPaths(root: root)
    let hosts = try paths.load([HostProfile].self, from: paths.hosts)
    guard hosts.count == 2, hosts.allSatisfy({ $0.address == "127.0.0.1" && [22281, 22282].contains($0.port) }) else {
        throw WorkbenchError.message("此检查工具仅允许操作 test-environment.sh 创建的两个回环地址测试节点。")
    }
    let sourceHost = hosts[0]; let targetHost = hosts[1]
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let engine = TransferEngine(transport: transport)
    let source = try transport.sftp(sourceHost); let target = try transport.sftp(targetHost)
    try check("未保存配置的 SSH / SFTP 测试连接") {
        let originalHosts = try Data(contentsOf: paths.hosts)
        var draft = sourceHost; draft.name = ""
        let result = try transport.testConnection(draft)
        try require(result.sftpAvailable && result.elapsed > 0, "SSH / SFTP 测试未通过")
        try require(Data(contentsOf: paths.hosts) == originalHosts, "测试连接修改了已保存的主机")
        draft.name = sourceHost.name
        let freshOptions = try transport.options(for: draft, reuseConnection: false)
        try require(freshOptions.prefix(4) == ["-o", "ControlMaster=no", "-o", "ControlPath=none"], "测试连接复用了旧通道")
        let flag = CancellationFlag(); flag.cancel()
        do { _ = try transport.testConnection(sourceHost, cancellation: flag); throw WorkbenchError.message("预取消的连接测试没有停止") }
        catch WorkbenchError.cancelled {}
    }
    try check("修改主机连接参数不复用旧主机通道") {
        let expected = try transport.run(targetHost, command: "hostname").checked().text
        var edited = sourceHost; edited.port = targetHost.port
        let actual = try transport.run(edited, command: "hostname").checked().text
        try require(actual == expected, "修改端口后仍连接到了旧主机")
    }
    let runID = String(UUID().uuidString.prefix(8)).lowercased()
    let sourceRoot = "/home/tester/verify-\(runID)"; let targetRoot = "/home/tester/incoming/verify-\(runID)"
    try source.mkdir(sourceRoot); try target.mkdir(targetRoot)
    let localRoot = root.deletingLastPathComponent().appendingPathComponent("verification-" + runID)
    try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
    if !stress {
        try check("本机与两台 SSH 主机的九方向多选文件及目录复制") {
            let profiles: [HostProfile?] = [nil, sourceHost, targetHost]
            let clients = try profiles.map { try transport.files($0) }
            defer { clients.forEach { $0.close() } }
            let directories = [localRoot.appendingPathComponent("matrix").path, sourceRoot + "/matrix", targetRoot + "/matrix"]
            let payload = Data("文件内容 · Farport\n".utf8)
            for index in profiles.indices {
                let client = clients[index]; let folder = directories[index]
                try client.mkdir(folder); try client.mkdir(folder + "/source"); try client.mkdir(folder + "/source/目录")
                try client.mkdir(folder + "/source/目录/empty")
                for path in [folder + "/source/说明.txt", folder + "/source/目录/子文件.txt"] {
                    try client.createFile(path); let original = try client.stat(path)
                    try client.saveText(path, data: payload, expected: original, original: Data())
                }
            }
            for sourceIndex in profiles.indices {
                for destinationIndex in profiles.indices {
                    let destinationFolder = directories[destinationIndex] + "/from-\(sourceIndex)"
                    let destinationClient = clients[destinationIndex]; try destinationClient.mkdir(destinationFolder)
                    let sourceDirectory = directories[sourceIndex] + "/source"
                    let selected = ["说明.txt", "目录"].map { FileEndpoint(hostID: profiles[sourceIndex]?.id, path: sourceDirectory + "/" + $0) }
                    let batch = try TransferBatch.jobs(sources: selected, destinationDirectory: FileEndpoint(hostID: profiles[destinationIndex]?.id, path: destinationFolder))
                    try require(batch.count == 2, "批量条目缺失")
                    for job in batch {
                        let copied = engine.execute(job, hosts: hosts, cancellation: CancellationFlag()) { _ in }
                        try require(copied.status == .completed, "\(sourceIndex)→\(destinationIndex)：\(copied.message)")
                    }
                    try require(destinationClient.preview(destinationFolder + "/说明.txt") == payload, "文件内容不一致")
                    try require(destinationClient.preview(destinationFolder + "/目录/子文件.txt") == payload, "文件夹内容不一致")
                    try require(destinationClient.stat(destinationFolder + "/目录/empty").isDirectory, "空文件夹未保留")
                    print("     PASS \(sourceIndex == 0 ? "Mac" : "SSH-\(sourceIndex)") → \(destinationIndex == 0 ? "Mac" : "SSH-\(destinationIndex)")")
                }
            }
        }
    }
    let sourceFile = sourceRoot + "/deploy-bundle.bin"
    let sourceSize = stress ? UInt64(10 * 1024 * 1024 * 1024) : UInt64(32 * 1024 * 1024)
    try check(stress ? "准备 10 GiB 大文件" : "准备随机文件") {
        if stress {
            let code = "from pathlib import Path; path=Path(\(String(reflecting: sourceFile))); file=path.open('wb'); file.truncate(\(sourceSize)); file.close()"
            _ = try transport.run(sourceHost, command: "python3 -c \(RemotePath.quote(code))").checked()
        } else {
            let handle = try source.openWrite(sourceFile, exclusive: true); defer { try? source.closeHandle(handle) }
            for index in 0..<16 { try source.write(handle, offset: UInt64(index * 2 * 1024 * 1024), data: randomData(2 * 1024 * 1024)) }
            try source.sync(handle)
        }
        try require(source.stat(sourceFile).size == sourceSize, "源文件大小不一致")
    }
    if stress {
        try check("10 GiB 跨主机流式传输与 SHA-256") {
            let job = TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: sourceFile), destination: FileEndpoint(hostID: targetHost.id, path: targetRoot + "/deploy-bundle.bin"))
            let clock = Date(); var lastPercentage = -1
            let completed = engine.execute(job, hosts: hosts, cancellation: CancellationFlag()) { progress in
                let percentage = Int(progress.fraction * 100)
                if percentage >= lastPercentage + 10 { print("     \(percentage)% · \(String(format: "%.1f", Date().timeIntervalSince(clock)))s"); lastPercentage = percentage }
            }
            try require(completed.status == .completed, completed.message)
            let sourceHash = try transport.run(sourceHost, command: "sha256sum \(RemotePath.quote(sourceFile))", timeout: 300).checked().text.split(separator: " ").first
            let targetHash = try transport.run(targetHost, command: "sha256sum \(RemotePath.quote(job.destination.path))", timeout: 300).checked().text.split(separator: " ").first
            try require(sourceHash == targetHash, "大文件哈希不匹配"); recordedJobs.append(completed)
        }
        try check("万级小文件目录传输") {
            let directory = sourceRoot + "/many-files"
            let code = "from pathlib import Path; root=Path(\(String(reflecting: directory))); root.mkdir(); [(root / ('file-%05d.txt' % index)).write_text('entry=%d\\n' % index) for index in range(10000)]"
            _ = try transport.run(sourceHost, command: "python3 -c \(RemotePath.quote(code))", timeout: 120).checked()
            let job = TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: directory), destination: FileEndpoint(hostID: targetHost.id, path: targetRoot + "/many-files"))
            var lastReport = Date()
            let completed = engine.execute(job, hosts: hosts, cancellation: CancellationFlag()) { progress in
                if Date().timeIntervalSince(lastReport) > 10 { print("     \(progress.message)"); lastReport = Date() }
            }
            try require(completed.status == .completed, completed.message)
            let listing = try target.list(job.destination.path)
            try require(listing.count == 10000, "目标条目数量不正确")
            let script = "import hashlib; from pathlib import Path; root=Path(__import__('sys').argv[1]); digest=hashlib.sha256(); [(digest.update(path.name.encode()), digest.update(path.read_bytes())) for path in sorted(root.iterdir())]; print(digest.hexdigest())"
            let sourceHash = try transport.run(sourceHost, command: "python3 -c \(RemotePath.quote(script)) \(RemotePath.quote(directory))", timeout: 120).checked().text
            let targetHash = try transport.run(targetHost, command: "python3 -c \(RemotePath.quote(script)) \(RemotePath.quote(job.destination.path))", timeout: 120).checked().text
            try require(sourceHash == targetHash, "目录内容校验失败"); recordedJobs.append(completed)
        }
    } else {
        try check("SFTP 路径、Unicode、重命名与权限") {
            let path = sourceRoot + "/中文 ' $() ; 文件.txt"
            let data = Data("你好，SSH Workbench。\n".utf8)
            let handle = try source.openWrite(path, exclusive: true); try source.write(handle, offset: 0, data: data); try source.closeHandle(handle)
            try require(source.preview(path) == data, "Unicode 文件内容不匹配")
            try require(source.list(sourceRoot).contains { $0.name == "中文 ' $() ; 文件.txt" }, "目录名称被错误解析")
            let renamed = sourceRoot + "/preview.txt"; try source.rename(path, to: renamed); try source.chmod(renamed, permissions: 0o640)
            try require(source.stat(renamed).permissions & 0o777 == 0o640, "权限未生效")
            let attributes = try source.stat(renamed); try source.saveText(renamed, data: Data("updated\n".utf8), expected: attributes)
            try require(source.preview(renamed) == Data("updated\n".utf8), "原子编辑未生效")
            do { try source.saveText(renamed, data: Data("stale".utf8), expected: attributes); throw WorkbenchError.message("编辑冲突未被拒绝") }
            catch let error as WorkbenchError { guard error.localizedDescription.contains("变化") else { throw error } }
            let sameSizeAttributes = try source.stat(renamed)
            let changedHandle = try source.openWrite(renamed, truncate: true)
            try source.write(changedHandle, offset: 0, data: Data("changed\n".utf8)); try source.closeHandle(changedHandle)
            try source.setModified(renamed, modified: sameSizeAttributes.modified)
            do { try source.saveText(renamed, data: Data("replace\n".utf8), expected: sameSizeAttributes, original: Data("updated\n".utf8)); throw WorkbenchError.message("同大小同时间戳的内容冲突未被拒绝") }
            catch let error as WorkbenchError { guard error.localizedDescription.contains("变化") else { throw error } }
        }
        try check("tmux 创建、枚举、窗口、窗格、重命名与结束") {
            let service = TmuxService(transport: transport, host: sourceHost); let name = "verify-" + runID
            try service.create(name: name)
            guard let session = try service.sessions().first(where: { $0.name == name }) else { throw WorkbenchError.message("未找到新会话") }
            defer { try? service.kill(session: session.id) }
            try service.createWindow(session: session.id)
            guard let pane = try service.panes().first(where: { $0.sessionID == session.id }) else { throw WorkbenchError.message("未找到窗格") }
            try service.split(pane: pane.id); try service.select(pane: pane)
            try service.rename(session: session.id, name: name + "-renamed")
            try require(service.sessions().contains { $0.name == name + "-renamed" }, "重命名未生效")
            try require(service.panes().filter { $0.sessionID == session.id }.count >= 3, "窗格数量不正确")
        }
        try check("跨主机暂停、断点校验、恢复及完整性") {
            let job = TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: sourceFile), destination: FileEndpoint(hostID: targetHost.id, path: targetRoot + "/deploy-bundle.bin"))
            let cancellation = CancellationFlag()
            let paused = engine.execute(job, hosts: hosts, cancellation: cancellation) { progress in if progress.status == .running && progress.completedBytes >= 2 * 1024 * 1024 { cancellation.cancel() } }
            try require(paused.status == .paused, "传输未暂停：\(paused.status) · \(paused.message)")
            try require(target.statIfExists(job.destination.path) == nil, "暂停时不应发布最终文件")
            let completed = engine.execute(paused, hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(completed.status == .completed, completed.message)
            let sourceHash = try transport.run(sourceHost, command: "sha256sum \(RemotePath.quote(sourceFile))").checked().text.split(separator: " ").first
            let targetHash = try transport.run(targetHost, command: "sha256sum \(RemotePath.quote(job.destination.path))").checked().text.split(separator: " ").first
            try require(sourceHash == targetHash, "断点恢复后的哈希不匹配"); recordedJobs.append(completed)
        }
        try check("本机下载、上传与同名冲突") {
            let localFile = localRoot.appendingPathComponent("download.bin").path
            let download = engine.execute(TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: sourceFile), destination: FileEndpoint(path: localFile)), hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(download.status == .completed, download.message)
            let uploadJob = TransferJob(source: FileEndpoint(path: localFile), destination: FileEndpoint(hostID: targetHost.id, path: targetRoot + "/upload.bin"))
            let upload = engine.execute(uploadJob, hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(upload.status == .completed, upload.message)
            let collision = engine.execute(uploadJob, hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(collision.status == .failed && collision.message.contains("目标已存在"), "同名文件被静默覆盖")
            recordedJobs += [download, upload]
        }
        try check("损坏断点拒绝续传") {
            let job = TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: sourceFile), destination: FileEndpoint(hostID: targetHost.id, path: targetRoot + "/corrupt.bin"))
            let flag = CancellationFlag()
            let paused = engine.execute(job, hosts: hosts, cancellation: flag) { progress in if progress.completedBytes >= 2 * 1024 * 1024 { flag.cancel() } }
            try require(paused.status == .paused, "未暂停")
            let partial = job.destination.path + ".swb-" + job.id.uuidString + ".part"
            let handle = try target.openWrite(partial); try target.write(handle, offset: 0, data: Data([0, 1, 2, 3, 4])); try target.closeHandle(handle)
            let result = engine.execute(paused, hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(result.status == .failed && result.message.contains("断点内容"), "损坏断点没有被发现")
        }
        try check("磁盘不足、权限不足不发布半成品") {
            let diskJob = TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: sourceFile), destination: FileEndpoint(hostID: targetHost.id, path: "/limited/verify-" + runID + ".bin"))
            let result = engine.execute(diskJob, hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(result.status == .failed, "磁盘不足未失败")
            try require(target.statIfExists(diskJob.destination.path) == nil, "磁盘不足仍发布了最终文件")
            let permissionJob = TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: sourceFile), destination: FileEndpoint(hostID: targetHost.id, path: "/root/forbidden.bin"))
            let denied = engine.execute(permissionJob, hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(denied.status == .failed, "权限不足没有失败")
        }
        try check("目录递归与符号链接保护") {
            let directory = sourceRoot + "/tree"; try source.mkdir(directory); try source.mkdir(directory + "/nested")
            try source.chmod(directory, permissions: 0o700)
            let handle = try source.openWrite(directory + "/nested/空文件.txt", exclusive: true); try source.closeHandle(handle)
            let job = TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: directory), destination: FileEndpoint(hostID: targetHost.id, path: targetRoot + "/tree"))
            let result = engine.execute(job, hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(result.status == .completed, result.message)
            try require(target.stat(job.destination.path + "/nested/空文件.txt").size == 0, "空文件未复制")
            try require(target.stat(job.destination.path).permissions & 0o777 == 0o700, "目标目录权限未保留")
            _ = try transport.run(sourceHost, command: "ln -s /etc/passwd \(RemotePath.quote(directory + "/external-link"))").checked()
            let linked = engine.execute(TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: directory), destination: FileEndpoint(hostID: targetHost.id, path: targetRoot + "/tree-link")), hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(linked.status == .failed && linked.message.contains("符号链接"), "错误地跟随了符号链接")
            try require(linked.entries.isEmpty, "扫描失败提交了部分清单")
            let fifoPath = sourceRoot + "/special-pipe"
            _ = try transport.run(sourceHost, command: "mkfifo \(RemotePath.quote(fifoPath))").checked()
            let special = engine.execute(TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: fifoPath), destination: FileEndpoint(hostID: targetHost.id, path: targetRoot + "/pipe")), hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(special.status == .failed && special.message.contains("管道"), "特殊文件未拒绝")
        }
        try check("两级 ProxyJump") {
            var jumped = sourceHost; jumped.id = UUID(); jumped.address = "swb-target"; jumped.port = 22
            jumped.identityFile = ""; jumped.jumpHost = "swb-jump-a,swb-jump-b"; jumped.configFile = root.deletingLastPathComponent().appendingPathComponent("ssh_config").path
            let result = try transport.run(jumped, command: "printf jump-ok", timeout: 40).checked()
            try require(result.text == "jump-ok", "跳板机链路失败"); transport.disconnectMaster(jumped)
        }
        try check("未知与变化的主机指纹拒绝连接") {
            let untrustedPaths = try ApplicationPaths(root: localRoot.appendingPathComponent("untrusted"))
            let untrusted = SSHTransport(paths: untrustedPaths, noninteractive: true)
            let rejected = try untrusted.run(sourceHost, command: "true", timeout: 15)
            try require(rejected.status != 0, "未知主机被静默信任")
            let known = try String(contentsOf: paths.knownHosts, encoding: .utf8)
            guard let secondKey = known.split(separator: "\n").first(where: { $0.hasPrefix("[127.0.0.1]:22282 ") }) else { throw WorkbenchError.message("缺少测试指纹") }
            let invalid = secondKey.replacingOccurrences(of: ":22282", with: ":22281")
            try Data((invalid + "\n").utf8).write(to: untrustedPaths.knownHosts)
            let changed = try untrusted.run(sourceHost, command: "true", timeout: 15)
            try require(changed.status != 0 && changed.error.contains("HOST IDENTIFICATION HAS CHANGED"), "主机指纹变化未阻止连接")
        }
        try check("命令超时与取消") {
            let started = Date()
            do { _ = try transport.run(sourceHost, command: "sleep 10", timeout: 0.5); throw WorkbenchError.message("未触发超时") }
            catch let error as WorkbenchError { try require(error.localizedDescription.contains("超时") && Date().timeIntervalSince(started) < 5, "超时未及时结束") }
        }
        try check("10 个并发真实 PTY 终端") {
            let group = DispatchGroup(); let barrier = DispatchSemaphore(value: 0); let results = ConcurrentResults()
            for _ in 0..<10 {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }; barrier.wait()
                    do {
                        let arguments = try transport.terminalArguments(for: sourceHost) + ["printf SWB_PTY_OK:; test -t 0 && printf yes; sleep 2"]
                        let result = try ProcessRunner.run(executable: "/usr/bin/ssh", arguments: arguments, environment: transport.environment(for: sourceHost), timeout: 15).checked()
                        if !result.text.contains("SWB_PTY_OK:yes") { results.failure("远端未分配 PTY") }
                    } catch { results.failure(error.localizedDescription) }
                }
            }
            for _ in 0..<10 { barrier.signal() }
            try require(group.wait(timeout: .now() + 25) == .success, "并发终端超时")
            try require(results.errors.isEmpty, results.errors.joined(separator: "\n"))
        }
        try check("两路并发传输与哈希校验") {
            let group = DispatchGroup(); let concurrent = ConcurrentResults()
            for index in 0..<2 {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    let job = TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: sourceFile), destination: FileEndpoint(hostID: targetHost.id, path: targetRoot + "/parallel-\(index).bin"))
                    let result = engine.execute(job, hosts: hosts, cancellation: CancellationFlag()) { _ in }
                    if result.status != .completed { concurrent.failure(result.message) }; concurrent.job(result)
                }
            }
            try require(group.wait(timeout: .now() + 60) == .success, "并发传输超时")
            try require(concurrent.errors.isEmpty, concurrent.errors.joined(separator: "\n"))
            let sourceHash = try transport.run(sourceHost, command: "sha256sum \(RemotePath.quote(sourceFile))").checked().text.split(separator: " ").first
            for job in concurrent.jobs {
                let targetHash = try transport.run(targetHost, command: "sha256sum \(RemotePath.quote(job.destination.path))").checked().text.split(separator: " ").first
                try require(sourceHash == targetHash, "并发传输内容不一致")
            }
        }
        try check("本地与 SOCKS5 转发端到端") {
            let serverPort = Int.random(in: 19000...22000)
            let started = try transport.run(sourceHost, command: "nohup python3 -m http.server \(serverPort) --bind 127.0.0.1 --directory /home/tester/workspace >\(RemotePath.quote(sourceRoot + "/http.log")) 2>&1 </dev/null & echo $!").checked()
            guard let serverPID = Int(started.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw WorkbenchError.message("测试 HTTP 服务启动失败") }
            defer { _ = try? transport.run(sourceHost, command: "kill \(serverPID)") }
            for kind in [ForwardingKind.local, .dynamic] {
                let port = Int.random(in: 30000...45000)
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = try transport.forwardingArguments(for: sourceHost, kind: kind, port: port, targetPort: serverPort)
                process.environment = transport.environment(for: sourceHost); process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
                var received = false
                for _ in 0..<15 {
                    Thread.sleep(forTimeInterval: 0.15)
                    let url = "http://127.0.0.1:\(kind == .local ? port : serverPort)/README.md"
                    let options = kind == .local ? ["--noproxy", "*"] : ["--noproxy", "", "--socks5-hostname", "127.0.0.1:\(port)"]
                    let response = try ProcessRunner.run(executable: "/usr/bin/curl", arguments: options + ["-fsS", "--max-time", "2", url], timeout: 3)
                    if response.status == 0 && response.text.contains("SSH Workbench") { received = true; break }
                }
                try require(received, "\(kind) 转发未通过 HTTP 内容验证")
            }
        }
        try check("远程转发端到端") {
            let localPort = Int.random(in: 45001...55000); let remotePort = Int.random(in: 22001...28000)
            let directory = localRoot.appendingPathComponent("http"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("SWB_REMOTE_FORWARD_OK".utf8).write(to: directory.appendingPathComponent("index.html"))
            let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = ["-m", "http.server", String(localPort), "--bind", "127.0.0.1", "--directory", directory.path]
            server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice; try server.run()
            defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
            let tunnel = Process(); tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            tunnel.arguments = try transport.forwardingArguments(for: sourceHost, kind: .remote, port: remotePort, targetPort: localPort)
            tunnel.environment = transport.environment(for: sourceHost); tunnel.standardInput = FileHandle.nullDevice; tunnel.standardOutput = FileHandle.nullDevice; tunnel.standardError = FileHandle.nullDevice; try tunnel.run()
            defer { if tunnel.isRunning { tunnel.terminate(); tunnel.waitUntilExit() } }
            Thread.sleep(forTimeInterval: 0.8)
            let code = "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:\(remotePort)/', timeout=3).read().decode())"
            let response = try transport.run(sourceHost, command: "python3 -c \(RemotePath.quote(code))").checked()
            try require(response.text.contains("SWB_REMOTE_FORWARD_OK"), "远程转发内容校验失败")
        }
        try check("连接中断后续传恢复") {
            let label = try ProcessRunner.run(executable: "/usr/bin/env", arguments: ["docker", "inspect", "-f", "{{index .Config.Labels \"local.sshworkbench.fixture\"}}", "swb-fixture-b"]).checked()
            try require(label.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true", "拒绝停止非测试容器")
            let job = TransferJob(source: FileEndpoint(hostID: sourceHost.id, path: sourceFile), destination: FileEndpoint(hostID: targetHost.id, path: targetRoot + "/recovered.bin"))
            var stopped = false
            let interrupted = engine.execute(job, hosts: hosts, cancellation: CancellationFlag()) { progress in
                if !stopped && progress.status == .running && progress.completedBytes >= 2 * 1024 * 1024 {
                    stopped = true
                    _ = try? ProcessRunner.run(executable: "/usr/bin/env", arguments: ["docker", "stop", "-t", "1", "swb-fixture-b"], timeout: 10)
                }
            }
            _ = try ProcessRunner.run(executable: "/usr/bin/env", arguments: ["docker", "start", "swb-fixture-b"], timeout: 20).checked()
            try require(stopped && interrupted.status == .failed, "未检测到连接中断")
            var ready = false
            for _ in 0..<15 {
                if let result = try? transport.run(targetHost, command: "true", timeout: 3), result.status == 0 { ready = true; break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            try require(ready, "目标 SSH 未恢复")
            let resumed = engine.execute(interrupted, hosts: hosts, cancellation: CancellationFlag()) { _ in }
            try require(resumed.status == .completed, resumed.message)
            let sourceHash = try transport.run(sourceHost, command: "sha256sum \(RemotePath.quote(sourceFile))").checked().text.split(separator: " ").first
            let targetHash = try transport.run(targetHost, command: "sha256sum \(RemotePath.quote(job.destination.path))").checked().text.split(separator: " ").first
            try require(sourceHash == targetHash, "网络恢复后的哈希不一致"); recordedJobs.append(resumed)
        }
    }
    try paths.save(recordedJobs, to: paths.transfers)
    let report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "mode": stress ? "stress" : "integration", "checks": results, "sourceDirectory": sourceRoot, "targetDirectory": targetRoot]
    let reportURL = root.deletingLastPathComponent().appendingPathComponent(stress ? "stress-report.json" : "integration-report.json")
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
    print("PASS · \(results.count) 组真实 SSH 检查；报告：\(reportURL.path)")
    source.close(); target.close()
} catch {
    fputs("验证失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
