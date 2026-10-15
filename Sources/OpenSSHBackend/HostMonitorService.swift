import Foundation
import WorkbenchCore

public struct HostMonitorService: Sendable {
    public let transport: SSHTransport
    public let host: HostProfile?
    public init(transport: SSHTransport, host: HostProfile?) { self.transport = transport; self.host = host }

    public func detect(cancellation: CancellationFlag) throws -> MonitorPlatform {
        if host == nil { return .macOS }
        let result = try run("uname -s", cancellation: cancellation, timeout: 8)
        if result.status == 255 { _ = try result.checked() }
        if result.status == 0 {
            if result.text.contains("Darwin") { return .macOS }
            if result.text.contains("Linux") {
                let android = try run("sh -c 'test -d /data/data/com.termux || test -n \"$TERMUX_VERSION\"'", cancellation: cancellation, timeout: 8)
                if android.status == 0 { return .termux }
                return .linux
            }
        }
        let windows = try run(Self.powershell("[Console]::Write('FARPORT_WINDOWS')"), cancellation: cancellation, timeout: 12)
        guard windows.status == 0, windows.text.contains("FARPORT_WINDOWS") else { throw WorkbenchError.message(L10n.text("无法识别目标系统，或目标没有可用的只读采集工具。")) }
        return .windows
    }

    public func sample(platform: MonitorPlatform, includeInfo: Bool, cancellation: CancellationFlag) throws -> MonitorSnapshot {
        let filename = platform == .windows ? "monitor-windows.ps1" : "monitor-posix.sh"
        let script = try Self.script(filename)
        let command: String
        let input: Data
        if platform == .windows {
            command = Self.powershell("[Console]::InputEncoding=New-Object System.Text.UTF8Encoding($false); & ([ScriptBlock]::Create([Console]::In.ReadToEnd()))")
            input = Data(("$IncludeInfo=$\(includeInfo ? "true" : "false");\n" + script).utf8)
        } else { command = "sh -s -- " + (includeInfo ? "info" : "sample"); input = Data(script.utf8) }
        let result = try run(command, cancellation: cancellation, timeout: 25, input: input)
        _ = try result.checked()
        return try MonitorSnapshot.parse(result.text, platform: platform)
    }
    private func run(_ command: String, cancellation: CancellationFlag, timeout: TimeInterval, input: Data? = nil) throws -> CommandResult {
        if let host {
            return try ProcessRunner.run(executable: "/usr/bin/ssh", arguments: transport.options(for: host) + [host.address, command], environment: transport.environment(for: host), cancellation: cancellation, timeout: timeout, input: input)
        }
        return try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", command], environment: LocalShellConfiguration().environment, cancellation: cancellation, timeout: timeout, input: input)
    }
    public static func powershell(_ script: String) -> String {
        "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + (script.data(using: .utf16LittleEndian) ?? Data()).base64EncodedString()
    }
    private static func script(_ name: String) throws -> String {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("SSHWorkbench_OpenSSHBackend.bundle")
        let bundle = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Resources") else { throw WorkbenchError.message(L10n.text("监控采集脚本资源缺失。")) }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
