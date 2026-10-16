import Foundation
import WorkbenchCore
import OpenSSHBackend

setenv("FARPORT_LANGUAGE", "zh-Hans", 0)

var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    checks += 1
    if try !condition() { throw WorkbenchError.message("断言失败：\(message)") }
}
func rejects(_ message: String, _ operation: () throws -> Void) throws {
    checks += 1
    do { try operation() } catch { return }
    throw WorkbenchError.message("未拒绝非法输入：\(message)")
}

do {
    if CommandLine.arguments.contains("--preview-lifecycle-check") { try checkPreviewLifecycle(); exit(0) }
    if CommandLine.arguments.contains("--preview-timeout-check") { try checkPreviewTimeout(); exit(0) }
    if let index = CommandLine.arguments.firstIndex(of: "--preview-lifecycle-ssh"), CommandLine.arguments.indices.contains(index + 1) { try checkRemotePreviewLifecycle(root: CommandLine.arguments[index + 1]); exit(0) }
    try checkSSHCompatibility()
    try checkAttachmentIdentity()
    if CommandLine.arguments.contains("--english-check") { try checkEnglishRuntime(); exit(0) }
    try checkHostMonitoring()
    if let index = CommandLine.arguments.firstIndex(of: "--monitor-check") { try checkLiveMonitor(arguments: Array(CommandLine.arguments.dropFirst(index + 1))) }
    try checkNavigationAndPreview()
    try checkCodeHighlighting()
    try checkSFTPNames()
    if let index = CommandLine.arguments.firstIndex(of: "--device-files-check") { try checkDeviceFiles(arguments: Array(CommandLine.arguments.dropFirst(index + 1))) }
    try checkFileSorting()
    try checkTransferConflicts()
    try checkPreviewServer()
    try checkPreviewLifecycle()
    try checkReleaseUpdates()
    if CommandLine.arguments.contains("--release-check") { try checkLiveRelease() }
    try expect(HostMarkColor.allCases.count == 10, "主机提供十种标记颜色")
    try expect(HostMarkColor(storedValue: "mint") == .mint && HostMarkColor(storedValue: "blue") == .blue, "旧颜色配置兼容")
    try expect(HostMarkColor(storedValue: "unknown") == .mint, "未知颜色有默认值")
    for color in HostMarkColor.allCases {
        let profile = HostProfile(name: "fixture", address: "localhost", color: color.rawValue)
        let restored = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(profile))
        try expect(restored.color == color.rawValue, "主机颜色持久化：\(color.title)")
    }
    try expect(TerminalFontSize.scaled(base: 14, magnification: 0.5) == 21, "双指放大字号")
    try expect(TerminalFontSize.scaled(base: 20, magnification: -0.25) == 15, "双指缩小字号")
    try expect(TerminalFontSize.scaled(base: 14, magnification: -2) == 10, "字号下限")
    try expect(TerminalFontSize.scaled(base: 14, magnification: 8) == 28, "字号上限")
    try expect(TerminalFontSize.scaled(base: 14, magnification: .nan) == 14, "忽略无效缩放值")
    let tmuxAttack = "test'; printf injection; #"
    let attachCommand = RemoteTmuxCommand.attach(session: tmuxAttack)
    try expect(attachCommand.contains("/bin/sh -c") && attachCommand.contains("/opt/homebrew/bin/tmux") && attachCommand.contains("/usr/local/bin/tmux"), "附着与管理共用远端 tmux 查找")
    let attachmentPath = "/work/图 ' 片.png"
    try expect(try AttachmentReference.text(paths: [attachmentPath]) == RemotePath.quote(attachmentPath) + " ", "附件路径引用转义且不提交")
    try rejects("拒绝本机相对路径作为远端附件") { _ = try AttachmentReference.text(paths: ["relative.png"]) }
    try rejects("拒绝附件路径控制字符") { _ = try AttachmentReference.text(paths: ["/tmp/a\nexecute"]) }
    let identity = AttachmentDeliveryIdentity(sessionID: UUID(), connectionID: UUID(), focusGeneration: 1, inputGeneration: 1)
    try expect(identity != AttachmentDeliveryIdentity(sessionID: identity.sessionID, connectionID: identity.connectionID, focusGeneration: 2, inputGeneration: 1), "切换标签后不能自动插入旧附件")
    try expect(identity != AttachmentDeliveryIdentity(sessionID: identity.sessionID, connectionID: UUID(), focusGeneration: 1, inputGeneration: 1), "重连后不能自动插入旧附件")
    try expect(identity != AttachmentDeliveryIdentity(sessionID: identity.sessionID, connectionID: identity.connectionID, focusGeneration: 1, inputGeneration: 2), "终端输入位置变化后不能自动插入旧附件")
    try expect(identity != AttachmentDeliveryIdentity(sessionID: identity.sessionID, connectionID: identity.connectionID, focusGeneration: 1, inputGeneration: 1, windowNumber: 7), "切换应用窗口后不能自动插入附件")
    let left = UUID(); let right = UUID(); let third = UUID()
    var layout = TerminalLayout(); layout.select(left); layout.split(with: right)
    layout.select(right)
    try expect(layout.primary == left && layout.secondary == right && layout.focused == right, "点击右侧标签保留分屏")
    layout.select(left)
    try expect(layout.primary == left && layout.secondary == right && layout.focused == left, "点击左侧标签保留分屏")
    layout.select(third)
    try expect(layout.primary == third && layout.secondary == nil, "新标签独立显示，不能携带旧标签右侧分栏")
    layout.select(left)
    try expect(layout.primary == left && layout.secondary == right, "返回原标签恢复整组分栏")
    layout.close(third, fallback: nil)
    try expect(layout.primary == left && layout.secondary == right, "关闭后台标签不改变前台分栏")
    let originalTab = layout.selectedTabID
    let originalRoot = layout.selectedTab!.root.id
    layout.resize(originalRoot, ratio: 0.63)
    let savedRoot = layout.selectedTab!.root
    layout.select(third); layout.selectTab(originalTab!)
    try expect(layout.selectedTab!.root == savedRoot, "切换标签保留用户分栏比例")
    layout.select(right); let bottom = UUID(); layout.split(with: bottom, axis: .topBottom)
    try expect(layout.tabs.count == 2 && layout.selectedTab!.terminals == [left, right, bottom], "右侧继续上下分栏仍属于一个标签")
    guard case .split(_, .leftRight, _, _, .split(_, .topBottom, _, _, _)) = layout.selectedTab!.root else { throw WorkbenchError.message("嵌套分栏方向不正确") }
    layout.focusNext(); try expect(layout.focused == left, "下一分栏循环回首项")
    layout.focusNext(backward: true); try expect(layout.focused == bottom, "上一分栏循环至末项")
    layout.toggleZoom(); try expect(layout.selectedTab!.zoomed && layout.selectedTab!.terminals.count == 3, "最大化不删除隐藏分栏")
    layout.select(third); try expect(layout.selectedTab!.zoomed == false, "最大化状态不泄漏到其他标签")
    layout.selectTab(originalTab!); try expect(layout.focused == bottom && layout.selectedTab!.zoomed, "返回标签保留焦点及最大化状态")
    layout.toggleZoom(); layout.close(right)
    try expect(layout.selectedTab!.terminals == [left, bottom], "关闭嵌套分栏只移除指定终端")
    layout.close(left); try expect(layout.primary == bottom && layout.secondary == nil, "关闭左分栏后保留右分栏且标签身份稳定")
    try expect(layout.selectedTabID == originalTab, "关闭标签首个终端仍保留标签身份")
    layout.close(bottom); try expect(layout.focused == third && layout.tabs.count == 1, "关闭最后分栏后切换到其他标签")
    layout.close(third); try expect(layout.tabs.isEmpty && layout.focused == nil, "最后标签关闭后布局为空")
    layout.select(left); layout.split(with: right); let preserved = layout.selectedTab!
    layout.select(third); layout.moveTab(third, before: left)
    try expect(layout.tabs.map(\.id) == [third, left] && layout.focused == third && layout.tabs[1] == preserved, "标签排序不改变分栏或焦点")
    layout.moveTab(third, before: nil)
    try expect(layout.tabs.map(\.id) == [left, third], "可移到最后")
    let beforeInvalidMove = layout; layout.moveTab(UUID(), before: left); layout.moveTab(left, before: UUID()); layout.moveTab(left, before: left)
    try expect(layout == beforeInvalidMove, "无效和原位排序不改变布局")
    let localSources = [FileEndpoint(path: "/source/文件.txt"), FileEndpoint(path: "/source/folder")]
    let batch = try TransferBatch.jobs(sources: localSources, destinationDirectory: FileEndpoint(path: "/destination"))
    try expect(batch.count == 2 && batch[1].destination.path == "/destination/folder", "批量文件及目录保留名称")
    try expect(try TransferBatch.jobs(sources: localSources + [localSources[0]], destinationDirectory: FileEndpoint(path: "/destination")).count == 2, "多选重复项只复制一次")
    try expect(try TransferBatch.jobs(sources: [FileEndpoint(path: "/source/folder"), FileEndpoint(path: "/source/folder/child")], destinationDirectory: FileEndpoint(path: "/destination")).count == 1, "多选父目录时不重复子项")
    try rejects("同目录复制") { _ = try TransferBatch.jobs(sources: localSources, destinationDirectory: FileEndpoint(path: "/source")) }
    try rejects("子目录循环复制") { _ = try TransferBatch.jobs(sources: [localSources[1]], destinationDirectory: FileEndpoint(path: "/source/folder/child")) }
    try rejects("规范化后的原位置") { _ = try TransferBatch.jobs(sources: localSources, destinationDirectory: FileEndpoint(path: "/source/other/..")) }
    try rejects("不同源同名条目") { _ = try TransferBatch.jobs(sources: [FileEndpoint(path: "/one/a"), FileEndpoint(path: "/two/a")], destinationDirectory: FileEndpoint(path: "/destination")) }
    try rejects("空批次") { _ = try TransferBatch.jobs(sources: [], destinationDirectory: FileEndpoint(path: "/destination")) }
    try rejects("根目录") { _ = try TransferBatch.jobs(sources: [FileEndpoint(path: "/")], destinationDirectory: FileEndpoint(path: "/destination")) }
    let remoteID = UUID()
    try expect(try TransferBatch.jobs(sources: localSources, destinationDirectory: FileEndpoint(hostID: remoteID, path: "/source")).count == 2, "不同主机允许相同路径")
    var writer = PacketWriter(); writer.uint64(UInt64.max); writer.string("文件 \" ' 😀")
    var reader = PacketReader(writer.data)
    try expect(reader.uint64() == UInt64.max, "64 位整数往返")
    try expect(reader.string() == "文件 \" ' 😀", "Unicode 和引号往返")
    try expect(reader.remaining == 0, "完整消费数据包")
    for count in 0..<4 {
        try rejects("截断头部 \(count)") { var packet = PacketReader(Data(repeating: 0, count: count)); _ = try packet.uint32() }
    }
    try rejects("超长字段") { var packet = PacketReader(Data([255, 255, 255, 255])); _ = try packet.string() }
    try rejects("非法 UTF-8") { var packet = PacketReader(Data([0, 0, 0, 1, 255])); _ = try packet.string() }
    try expect(RemotePath.join("/", "file") == "/file", "根目录拼接")
    try expect(RemotePath.join("/home/user/", "文件") == "/home/user/文件", "目录拼接")
    try expect(RemotePath.parent("/file") == "/", "父目录")
    for name in ["", ".", "..", "../file", "a/b", "a\0b", "a\nb"] { try expect(!RemotePath.validName(name), "文件名校验") }
    for address in ["-oProxyCommand=sh", "a b", "foo\nbar", "user@host", "/bin/sh", ""] {
        try rejects("主机地址 \(address)") { try HostProfile(name: "invalid", address: address).validate() }
    }
    try HostProfile(name: "IPv6", address: "::1", username: "user").validate()
    try rejects("无效端口") { try HostProfile(name: "host", address: "localhost", port: 0).validate() }
    try rejects("用户名选项注入") { try HostProfile(name: "host", address: "localhost", username: "-root").validate() }
    let quoted = "hello'; printf injected; echo '"
    let result = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "printf '%s' \(RemotePath.quote(quoted))"]).checked()
    try expect(result.text == quoted, "shell 引号阻止命令注入")
    let job = TransferJob(source: FileEndpoint(path: "/tmp/a"), destination: FileEndpoint(hostID: UUID(), path: "/tmp/b"))
    let restored = try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job))
    try expect(restored.id == job.id && restored.source == job.source, "断点清单往返")
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("farport-core-" + UUID().uuidString)
    let paths = try ApplicationPaths(root: temporaryRoot)
    defer { try? FileManager.default.removeItem(at: temporaryRoot); try? FileManager.default.removeItem(at: paths.sockets) }
    let shell = try LocalShellConfiguration(shell: "/bin/zsh", home: temporaryRoot, inheritedEnvironment: [
        "PATH": "/example/bin:/usr/bin:/bin", "LANG": "zh_CN.UTF-8", "TERM": "dumb", "HOME": "/incorrect",
        "SHELL": "/bin/false", "SWB_CREDENTIAL_ACCOUNT": "fixture", "SWB_QA_OUTPUT": "fixture.png",
        "SSH_ASKPASS": "/fixture/askpass", "SSH_ASKPASS_REQUIRE": "force", "SSH_CONNECTION": "remote", "SSH_AUTH_SOCK": "/fixture/agent"
    ])
    try expect(shell.executable == "/bin/zsh" && shell.executableName == "-zsh", "直接启动用户登录 Shell 而非 SSH")
    try expect(shell.directory == temporaryRoot.path && shell.environment["HOME"] == temporaryRoot.path && shell.environment["PWD"] == temporaryRoot.path, "本机 Shell 从主目录启动")
    try expect(shell.environment["SHELL"] == "/bin/zsh" && shell.environment["TERM_PROGRAM"] == "Farport", "本机终端环境标识")
    try expect(shell.environment["TERM"] == "xterm-256color" && shell.environment["COLORTERM"] == "truecolor", "本机与 SSH 终端色彩能力一致")
    try expect(shell.environment["PATH"] == "/example/bin:/usr/bin:/bin" && shell.environment["LANG"] == "zh_CN.UTF-8", "保留用户路径与语言")
    try expect(!shell.environment.keys.contains(where: { $0.hasPrefix("SWB_") }) && shell.environment["SSH_ASKPASS"] == nil && shell.environment["SSH_ASKPASS_REQUIRE"] == nil && shell.environment["SSH_CONNECTION"] == nil, "本机 Shell 不继承内部凭据提示和测试变量")
    try expect(shell.environment["SSH_AUTH_SOCK"] == "/fixture/agent", "保留用户 SSH Agent")
    let fallbackEnvironment = try LocalShellConfiguration(shell: "/bin/zsh", home: temporaryRoot, inheritedEnvironment: [:])
    try expect(fallbackEnvironment.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin" && fallbackEnvironment.environment["LANG"] == "en_US.UTF-8", "Finder 启动时补全基础环境")
    try expect(LocalShellConfiguration.userShell.hasPrefix("/"), "从系统账户读取登录 Shell")
    try rejects("无效 Shell") { _ = try LocalShellConfiguration(shell: "/not-a-shell", home: temporaryRoot) }
    try rejects("Shell 目录不是可执行文件") { _ = try LocalShellConfiguration(shell: "/bin", home: temporaryRoot) }
    try rejects("主目录不存在") { _ = try LocalShellConfiguration(shell: "/bin/zsh", home: temporaryRoot.appendingPathComponent("missing")) }
    let transport = SSHTransport(paths: paths, noninteractive: true)
    let originalHost = HostProfile(name: "fixture", address: "127.0.0.1", username: "tester")
    let options = try transport.options(for: originalHost)
    let control = options.first { $0.hasPrefix("ControlPath=") }!
    let expandedLength = control.dropFirst("ControlPath=".count).replacingOccurrences(of: "%C", with: String(repeating: "a", count: 40)).utf8.count
    try expect(expandedLength + 17 < 104, "socket 路径为随机后缀预留空间")
    var modifiedHost = originalHost; modifiedHost.port = 2222
    let changedOptions = try transport.options(for: modifiedHost)
    try expect(changedOptions.first { $0.hasPrefix("ControlPath=") } != control, "编辑端口隔离连接复用")
    let cancelled = CancellationFlag(); cancelled.cancel()
    try rejects("取消标记") { try cancelled.check() }
    for length in 0..<512 {
        let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var packet = PacketWriter(); packet.bytes(data); var parsed = PacketReader(packet.data)
        try expect(parsed.bytes() == data, "二进制字段往返 \(length)")
    }
    print("PASS · \(checks) 项核心断言")
} catch {
    fputs("FAIL · \(error.localizedDescription)\n", stderr)
    exit(1)
}
