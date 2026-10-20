import AppKit
import Foundation
import WorkbenchCore

@MainActor
enum LocalTerminalChecks {
    static func run(workspace: Workspace, mixed: Bool) async throws {
        let originalHosts = workspace.store.hosts
        let socketsBefore = try FileManager.default.contentsOfDirectory(atPath: workspace.store.paths.sockets.path)
        workspace.openLocalTerminal()
        guard let local = workspace.selectedTerminal, local.isLocal else { throw WorkbenchError.message("未创建本机终端") }
        try await wait("本机 Shell 未启动") { local.connected && local.terminal.process.running }
        local.terminal.send(txt: "if [ -t 0 ] && [ -t 1 ]; then printf '\\n%s%s\\n' 'FARPORT_' 'LOCAL_PTY_OK'; fi; case $- in *i*) printf '%s%s\\n' 'FARPORT_' 'INTERACTIVE_OK';; esac; case \"$0\" in -*) printf '%s%s\\n' 'FARPORT_' 'LOGIN_OK';; esac; if [ \"$(/bin/pwd -P)\" = \"$(cd -- \"$HOME\" && /bin/pwd -P)\" ]; then printf '%s%s\\n' 'FARPORT_' 'HOME_OK'; fi; printf '%s%s\\n' '中文输入输出' '验证'; if [ \"$TERM\" = 'xterm-256color' ]; then printf '%s%s\\n' 'FARPORT_' 'TERM_OK'; fi\n")
        for marker in ["FARPORT_LOCAL_PTY_OK", "FARPORT_INTERACTIVE_OK", "FARPORT_LOGIN_OK", "FARPORT_HOME_OK", "FARPORT_TERM_OK", "中文输入输出验证"] {
            try await wait("本机终端未返回预期标记：\(marker)") { hasLine(marker, session: local) }
        }
        guard local.terminal.findNext("中文输入输出验证"), local.state == "运行中" else { throw WorkbenchError.message("本机终端搜索或状态不正确") }
        local.terminal.clearSearch()
        guard try FileManager.default.contentsOfDirectory(atPath: workspace.store.paths.sockets.path) == socketsBefore else {
            throw WorkbenchError.message("本机终端不应创建 SSH 控制通道")
        }
        print("PASS · 本机真实 PTY、交互登录 Shell、主目录、中文输出、搜索与独立于 SSH")

        local.terminal.send(txt: "exit\n")
        try await wait("本机 exit 未结束会话") { !local.connected && !local.terminal.process.running }
        guard local.state == "已结束" else { throw WorkbenchError.message("本机退出状态错误") }
        local.reconnect()
        try await wait("本机终端无法重新打开") { local.connected && local.terminal.process.running }
        local.terminal.send(txt: "printf '\\n%s%s\\n' 'FARPORT_' 'REOPENED_OK'\n")
        try await wait("重新打开后的 Shell 没有响应") { hasLine("FARPORT_REOPENED_OK", session: local) }
        print("PASS · 本机 exit 与重新打开")

        let count = workspace.sessions.count
        workspace.openLocalTerminal()
        guard workspace.sessions.count == count, workspace.selectedTerminalID == local.id else { throw WorkbenchError.message("重复选择侧栏入口不应隐式新建终端") }
        guard let menu = NSApp.mainMenu, let localCommand = findCommand("新建本机终端", menu: menu),
              localCommand.keyEquivalent == "t", localCommand.keyEquivalentModifierMask == [.command, .shift] else {
            throw WorkbenchError.message("新建本机终端菜单的快捷键声明不正确")
        }
        workspace.connectLocal()
        guard workspace.sessions.count == count + 1 else { throw WorkbenchError.message("新建本机终端未生效") }
        guard let additional = workspace.selectedTerminal, additional.isLocal, additional.id != local.id else { throw WorkbenchError.message("本机快捷键打开了错误类型的终端") }
        try await wait("第二个本机终端未运行") { additional.connected }
        workspace.close(additional)
        try await wait("关闭本机标签未结束对应进程") { !additional.terminal.process.running }
        guard local.connected else { throw WorkbenchError.message("关闭一个终端影响了其他本机终端") }

        workspace.newTerminal(split: true)
        guard workspace.splitTerminalID != nil else { throw WorkbenchError.message("本机分屏未生效") }
        guard let second = workspace.selectedTerminal, second.isLocal else { throw WorkbenchError.message("本机分屏创建错误") }
        try await wait("本机分屏未启动") { second.connected }
        let left = workspace.layout.primary; let right = workspace.layout.secondary
        workspace.selectTerminal(local); workspace.selectTerminal(second)
        guard workspace.layout.primary == left, workspace.layout.secondary == right else { throw WorkbenchError.message("本机标签切换拆除了分屏") }
        workspace.page = .files; workspace.page = .terminal
        guard workspace.selectedTerminal?.isLocal == true, workspace.layout.primary == left, workspace.layout.secondary == right else {
            throw WorkbenchError.message("工作区切换丢失本机会话")
        }
        workspace.close(second)
        try await wait("本机分屏进程未关闭") { !second.terminal.process.running }
        print("PASS · 本机菜单快捷键声明、多标签、分屏及独立关闭；全局按键派发需前台交互验收")

        if mixed {
            guard let host = originalHosts.first, host.address == "127.0.0.1", [22281, 22282].contains(host.port) else {
                throw WorkbenchError.message("混合分屏检查仅允许隔离 SSH 主机")
            }
            workspace.connect(host, split: true)
            guard let remote = workspace.selectedTerminal, !remote.isLocal else { throw WorkbenchError.message("未创建混合 SSH 终端") }
            try await wait("混合分屏 SSH 未连接", timeout: 25) { remote.connected }
            remote.terminal.send(txt: "printf '\\n%s%s\\n' 'FARPORT_' 'REMOTE_PTY_OK'\n")
            try await wait("混合分屏 SSH 无输出") { hasLine("FARPORT_REMOTE_PTY_OK", session: remote) }
            workspace.selectTerminal(local); workspace.page = .files; workspace.page = .terminal
            guard workspace.primaryTerminal?.id == local.id, workspace.splitTerminalID == remote.id,
                  workspace.selectedHostID == nil, workspace.browsingLocalFiles else { throw WorkbenchError.message("混合分屏未保留本机身份与布局") }
            guard local.terminal.font == remote.terminal.font,
                  local.terminal.nativeBackgroundColor == remote.terminal.nativeBackgroundColor,
                  local.terminal.nativeForegroundColor == remote.terminal.nativeForegroundColor else { throw WorkbenchError.message("本机与 SSH 终端外观不一致") }
            workspace.selectTerminal(remote)
            guard workspace.selectedHostID == host.id, !workspace.browsingLocalFiles else { throw WorkbenchError.message("混合分屏的 SSH 身份错误") }
            workspace.selectTerminal(local)
            print("PASS · 本机与 SSH 混合分屏、主机身份与视觉参数一致")
        }
        guard workspace.store.hosts == originalHosts else { throw WorkbenchError.message("本机终端不应修改 SSH 主机配置") }
        local.terminal.send(txt: "clear; printf '\\033[1;36m栖远 Farport · 本机终端\\033[0m\\n\\n'; printf '登录 Shell：%s\\n' \"$0\"; printf '真实终端：'; tty; printf '\\n系统：'; uname -sm; printf '\\n中文与 Unicode：你好，Farport ✓\\n\\n'; printf '多标签 · 分屏 · 搜索 · 系统配色\\n'\n")
    }

    private static func hasLine(_ value: String, session: TerminalSession) -> Bool {
        let terminal = session.terminal.getTerminal()
        return (0..<terminal.rows).contains { row in
            terminal.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).trimmingCharacters(in: .whitespacesAndNewlines) == value
        }
    }
    private static func wait(_ failure: String, timeout: TimeInterval = 15, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw WorkbenchError.message(failure) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func findCommand(_ title: String, menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let result = findCommand(title, menu: submenu) { return result }
        }
        return nil
    }
}
