import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkDockerEngineIdentity() throws {
    let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("farport-engine-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let scenario = root.appendingPathComponent("scenario.json")
    func configure(_ value: [String: Any]) throws { try JSONSerialization.data(withJSONObject: value).write(to: scenario, options: .atomic) }
    try configure([:])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("docker_engine_identity_fixture.py").path, root.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { process.terminate(); process.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("engine.sock")
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: socket.path) {
        guard process.isRunning, Date() < deadline else { throw WorkbenchError.message("Docker身份socket夹具未就绪") }
        Thread.sleep(forTimeInterval: 0.01)
    }
    let endpoint = "unix://" + socket.path
    let identity = try DockerEngineIdentity.read(endpoint: endpoint)
    try expect(identity.apiVersion == "1.53" && identity.identifier == "fixture-daemon", "本机socket协商API版本并读取daemon身份")
    try configure(["version": ["status": 500]])
    try expect(try DockerEngineIdentity.read(endpoint: endpoint, apiVersion: identity.apiVersion) == identity, "复核时复用已协商版本而非重复发现")
    for version in ["", "1", "1.2.3", "1.53/../info", "1.５３", "1234.1", "1.", "1.2?secret=fixture"] {
        try configure(["version": ["body": ["ApiVersion": version]]])
        try rejects("拒绝畸形或可改变请求路径的API版本") { _ = try DockerEngineIdentity.read(endpoint: endpoint) }
    }
    for field in ["version", "info"] {
        for status in [301, 302, 401, 403, 404, 500] {
            try configure([field: ["status": status]])
            try rejects("身份接口非200不跟随跳转也不静默通过") { _ = try DockerEngineIdentity.read(endpoint: endpoint) }
        }
        for raw in ["not-json", "[]", "null", "{}"] {
            try configure([field: ["raw": raw]])
            try rejects("身份JSON损坏或缺字段不回退为成功") { _ = try DockerEngineIdentity.read(endpoint: endpoint) }
        }
    }
    for identifier in ["", "changed\nvalue", "with space", String(repeating: "a", count: 257)] {
        try configure(["info": ["body": ["ID": identifier]]])
        try rejects("空白或超长daemon身份不能绑定") { _ = try DockerEngineIdentity.read(endpoint: endpoint, apiVersion: identity.apiVersion) }
    }
    try configure(["info": ["body": ["ID": "replaced-daemon"]]])
    try expect(try DockerEngineIdentity.read(endpoint: endpoint, apiVersion: identity.apiVersion) != identity, "不缓存daemon身份而漏掉服务替换")
    try configure(["info": ["raw": String(repeating: "a", count: 2 * 1024 * 1024 + 1)]])
    try rejects("超限身份响应不能通过") { _ = try DockerEngineIdentity.read(endpoint: endpoint, apiVersion: identity.apiVersion) }
    let cancelled = CancellationFlag(); cancelled.cancel()
    try rejects("取消后不发起身份请求") { _ = try DockerEngineIdentity.read(endpoint: endpoint, cancellation: cancelled) }
    try configure(["info": ["delay": 1]])
    let delayed = CancellationFlag()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { delayed.cancel() }
    let started = ProcessInfo.processInfo.systemUptime
    do { _ = try DockerEngineIdentity.read(endpoint: endpoint, apiVersion: identity.apiVersion, cancellation: delayed); throw WorkbenchError.message("未取消延迟身份请求") }
    catch WorkbenchError.cancelled {}
    try expect(ProcessInfo.processInfo.systemUptime - started < 1, "身份请求等待可及时取消")
    for endpoint in ["tcp://localhost:2375", "ssh://host", "unix://other/tmp/docker.sock", "unix:///tmp/docker.sock?query=1"] {
        try rejects("身份快速通道不扩展到远程或畸形端点") { _ = try DockerEngineIdentity.read(endpoint: endpoint) }
    }
    let requests = try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8).split(separator: "\n")
    try expect(requests.allSatisfy { $0 == "/version" || $0 == "/v1.53/info" }, "只发起约定身份GET且无跳转或注入路径")
    print("PASS · Docker本机socket身份、版本、HTTP失败、畸形/超限响应、服务替换与取消保护")
}
