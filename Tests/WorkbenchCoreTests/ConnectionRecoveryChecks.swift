import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkConnectionRecovery() throws {
    let network = TerminalProcessExit(waitStatus: 255 << 8)
    try expect(network.code == 255 && network.signal == nil && network.shouldRecoverSSH, "正确解码SwiftTerm原始waitpid网络退出状态")
    try expect(!TerminalProcessExit(waitStatus: 0).shouldRecoverSSH, "正常logout不自动重连")
    try expect(!TerminalProcessExit(waitStatus: 1 << 8).shouldRecoverSSH, "tmux会话结束或远端命令退出1不循环重建")
    try expect(TerminalProcessExit(waitStatus: 15).signal == 15, "进程信号退出与命令退出码分开")
    try expect(TerminalProcessExit(waitStatus: nil).shouldRecoverSSH, "未知异常断开可进入受控恢复")
    var retry = SSHRetryPolicy()
    try expect((0..<8).map { _ in retry.nextDelay() } == [1, 2, 4, 8, 15, 30, 30, 30], "重试有上限退避，不形成连接风暴")
    try expect(retry.nextDelay(stableDuration: 31) == 1, "仅稳定运行后重置退避")
    for reason in ["Connection refused", "connection reset by peer", "Connection timed out during banner exchange", "No route to host", "Could not resolve hostname", "操作超时，连接已关闭。"] {
        try expect(SSHRetryPolicy.permitsRetry(diagnostic: reason), "暂时网络故障可以重试")
    }
    for reason in ["Permission denied (publickey)", "REMOTE HOST IDENTIFICATION HAS CHANGED!", "Host key verification failed", "no matching host key type found", "Unknown error", "Connection reset: Permission denied"] {
        try expect(!SSHRetryPolicy.permitsRetry(diagnostic: reason), "认证、指纹、配置及未知错误不盲目重试")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farport-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try ApplicationPaths(root: root)
    let host = HostProfile(name: "test", address: "host.example")
    let silent = SSHTransport(paths: paths, askpass: "/helper", silentAuthentication: true)
    let options = try silent.options(for: host)
    try expect(options.contains("StrictHostKeyChecking=yes") && !options.contains("StrictHostKeyChecking=ask"), "自动恢复不自动接受指纹")
    try expect(options.contains("NumberOfPasswordPrompts=1") && silent.environment(for: host)["SWB_SILENT_AUTH"] == "1", "自动恢复仅允许静默凭据读取")
    try expect(options.contains("ServerAliveInterval=15") && options.contains("ServerAliveCountMax=3"), "保持原有心跳容错，不因急切恢复缩短容忍窗口")
    let withoutHelper = SSHTransport(paths: paths, silentAuthentication: true)
    try expect(try withoutHelper.options(for: host).contains("BatchMode=yes"), "无静默助手时不退回终端密码交互")
    let manual = SSHTransport(paths: paths, askpass: "/helper")
    try expect(manual.environment(for: host)["SWB_SILENT_AUTH"] == nil, "手动验证不继承静默标志")
}
