import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkHostMonitoring() throws {
    let oldText = "FARPORT_MONITOR_V1\ninfo\tos\tFixture OS\ncpu\t1000\t400\nuptime\t300\nmemory\t1000\t600\nprocess\t12\t1000\t128\t3\t20\tdemo\tstart1\nnetwork\teth0\t1000\t2000\ndisk\t/data\t1000\t200\t800\nport\tTCP\t[::]:22\t*\tLISTEN\t12\n"
    let newText = oldText.replacingOccurrences(of: "1000\t400", with: "1200\t500").replacingOccurrences(of: "uptime\t300", with: "uptime\t302").replacingOccurrences(of: "128\t3", with: "128\t6").replacingOccurrences(of: "eth0\t1000\t2000", with: "eth0\t1400\t3000")
    let old = try MonitorSnapshot.parse(oldText, platform: .linux, date: Date(timeIntervalSince1970: 100))
    var current = try MonitorSnapshot.parse(newText, platform: .linux, date: Date(timeIntervalSince1970: 102))
    try expect(current.cpuPercent == nil && current.processes[0].cpuPercent == nil && current.networks[0].receiveRate == nil, "首个采样不伪造 CPU/网速")
    current.measure(since: old)
    try expect(current.cpuPercent == 50 && current.processes[0].cpuPercent == 150, "系统 CPU 与进程单核百分比计算")
    try expect(current.networks[0].receiveRate == 200 && current.networks[0].sendRate == 500, "网卡上下行差分字节率")
    try expect(current.ports[0].pid == 12 && current.ports[0].local == "[::]:22", "IPv6 监听地址保留")
    try expect(MonitorSnapshot.linuxAddress("0100007F:1F90") == "127.0.0.1:8080", "Linux proc IPv4 字节序")
    try expect(MonitorSnapshot.linuxAddress("00000000000000000000000001000000:0016") == "[0:0:0:0:0:0:0:1]:22", "Linux proc IPv6 字节序")
    try expect(MonitorSnapshot.linuxAddress("BAD:PORT") == nil, "异常端口地址不猜测")
    var reused = try MonitorSnapshot.parse(newText.replacingOccurrences(of: "start1", with: "start2"), platform: .linux, date: current.date)
    reused.measure(since: old)
    try expect(reused.processes[0].cpuPercent == nil, "PID 重用不混入旧 CPU 数据")
    var reset = try MonitorSnapshot.parse(newText.replacingOccurrences(of: "eth0\t1400\t3000", with: "eth0\t1\t2").replacingOccurrences(of: "uptime\t302", with: "uptime\t1"), platform: .linux, date: current.date)
    reset.measure(since: old)
    try expect(reset.networks[0].receiveRate == nil && reset.cpuPercent == nil, "主机重启或计数器回绕不产生负速率")
    try rejects("拒绝未知监控协议") { _ = try MonitorSnapshot.parse("unexpected", platform: .linux) }
    let invalid = try MonitorSnapshot.parse("FARPORT_MONITOR_V1\nmemory\t100\t200\ncpuPercent\tNaN\nprocess\t1\t\t-1\tbad\t\tx\t\n", platform: .termux)
    try expect(invalid.memoryUsed == nil && invalid.cpuPercent == nil && invalid.processes[0].residentBytes == nil, "无效数据不伪造可用值")
    let windows = try MonitorSnapshot.parse("\u{feff}FARPORT_MONITOR_V1\r\ninfo\tos\tWindows Fixture\r\nmemory\t8589934592\t4294967296\r\nprocess\t88\t\t12345\t4.5\t10\tservice\t638000000000000000\r\nport\tTCP\t[0.0.0.0]:3389\t*\tLISTEN\t88\r\n", platform: .windows)
    try expect(windows.processes.count == 1 && windows.info["os"] == "Windows Fixture", "Windows UTF8 BOM/CRLF 响应解析")
    let command = HostMonitorService.powershell("[Console]::Write('中文')")
    let encoded = command.components(separatedBy: " ").last!
    try expect(String(data: Data(base64Encoded: encoded)!, encoding: .utf16LittleEndian) == "[Console]::Write('中文')", "PowerShell 固定脚本UTF16编码，不拼接用户命令")
    let stdin = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-s"], input: Data("printf 'monitor-stdin-check'\n".utf8)).checked()
    try expect(stdin.text == "monitor-stdin-check", "采集脚本通过标准输入执行，不依赖长SSH命令参数")
    let host = HostProfile(name: "fixture", address: "localhost")
    let oldData = try JSONEncoder().encode(host)
    try expect(try JSONDecoder().decode(HostProfile.self, from: oldData).attachmentInsertion == nil, "旧主机配置兼容可选附件策略")
    for policy in AttachmentInsertionPolicy.allCases {
        var configured = host; configured.attachmentInsertion = policy
        try expect(try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(configured)).attachmentInsertion == policy, "附件策略往返持久化")
    }
    try expect(AttachmentInsertionPolicy.inherit.automatic(defaultValue: true) && !AttachmentInsertionPolicy.inherit.automatic(defaultValue: false), "继承全局附件策略")
    try expect(AttachmentInsertionPolicy.automatic.automatic(defaultValue: false) && !AttachmentInsertionPolicy.manual.automatic(defaultValue: true), "每主机覆盖全局策略")
}

func checkLiveMonitor(arguments: [String]) throws {
    let root = URL(fileURLWithPath: ".test/monitor-check").standardizedFileURL
    let paths = try ApplicationPaths(root: root)
    let host: HostProfile?
    if arguments.isEmpty { host = nil }
    else {
        guard arguments.count == 3, let port = Int(arguments[1]) else { throw WorkbenchError.message("需要地址、端口、用户") }
        try Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")).write(to: paths.knownHosts)
        host = HostProfile(name: "只读监控验收", address: arguments[0], port: port, username: arguments[2])
    }
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let service = HostMonitorService(transport: transport, host: host)
    let platform = try service.detect(cancellation: CancellationFlag())
    let first = try service.sample(platform: platform, includeInfo: true, cancellation: CancellationFlag())
    Thread.sleep(forTimeInterval: 1)
    var second = try service.sample(platform: platform, includeInfo: false, cancellation: CancellationFlag())
    second.measure(since: first)
    try expect(!first.info.isEmpty, "真实监控系统与用户信息返回")
    if platform == .macOS { try expect(second.memoryTotal != nil && !second.processes.isEmpty && !second.networks.isEmpty, "本机真实 CPU/内存/进程/网络采集") }
    print("PASS · 真实 \(platform.rawValue) 只读监控：\(second.processes.count) 进程、\(second.networks.count) 网卡、\(second.disks.count) 磁盘、\(second.ports.count) 端口；不写远端文件")
}
