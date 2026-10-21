import WorkbenchCore
import SwiftUI
import AppKit
import Darwin

@main
struct SSHWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var store = AppStore.shared
    init() { signal(SIGPIPE, SIG_IGN) }
    var body: some Scene {
        WindowGroup(L10n.text("栖远 Farport"), id: "workspace") {
            WorkspaceRoot(store: store)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(store.colorScheme)
                .tint(.teal)
                .environment(\.locale, L10n.language.locale)
        }
        .defaultSize(width: 1360, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands { WorkbenchCommands() }
        Settings { PreferencesView(store: store).environment(\.locale, L10n.language.locale) }
        Window(L10n.text("软件更新"), id: "updates") { UpdateView(updater: .shared) }.windowResizability(.contentSize)
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        UpdateController.shared.checkIfEnabled()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = AppStore.shared
        if (store.activeCount > 0 || store.screenSharingSessions.contains(where: \.running) || store.webServices.contains(where: \.running)) && ProcessInfo.processInfo.environment["SWB_QA_EXIT"] != "1" {
            let alert = NSAlert(); alert.messageText = L10n.text("暂停传输并退出？"); alert.informativeText = L10n.text("未完成的任务会保留断点。SSH 终端、桌面及网页服务通道将关闭；远端 tmux 会话不会因此被结束。"); alert.addButton(withTitle: L10n.text("暂停并退出")); alert.addButton(withTitle: L10n.text("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        store.prepareToQuit()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct WorkbenchCommands: Commands {
    @FocusedObject private var workspace: Workspace?
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.text("关于栖远 Farport")) {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: L10n.text("栖远 Farport"),
                    .applicationVersion: UpdateController.shared.currentVersion,
                    .credits: NSAttributedString(string: L10n.text("连接远方，安放工作。\n\n原生 SSH · tmux 工作区 · 远程文件传输"))
                ])
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(L10n.text("新建窗口")) { openWindow(id: "workspace") }.keyboardShortcut("n")
            Button(L10n.text("新建终端")) { workspace?.newTerminal() }.keyboardShortcut("t").disabled(workspace == nil)
            Button(L10n.text("新建本机终端")) { workspace?.connectLocal() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(workspace == nil)
            Button(L10n.text("左右分栏")) { workspace?.splitCurrentWorkspace() }.keyboardShortcut("d").disabled(workspace?.page != .terminal && workspace?.page != .files)
            Button(L10n.text("上下分栏")) { workspace?.splitCurrentWorkspace(axis: .topBottom) }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(workspace?.page != .terminal && workspace?.page != .files)
        }
        CommandGroup(after: .appInfo) {
            Button(L10n.text("检查更新…")) { openWindow(id: "updates"); UpdateController.shared.check() }
        }
        CommandMenu(L10n.text("终端")) {
            Button(L10n.text("重新连接当前终端")) { workspace?.selectedTerminal?.requestManualReconnect() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(workspace?.selectedTerminal == nil)
            Button(L10n.text("复制连接诊断")) { workspace?.selectedTerminal?.copyConnectionDiagnostics() }.disabled(workspace?.selectedTerminal == nil)
            Divider()
            Button(L10n.text("上一个分栏")) { workspace?.focusNextPane(backward: true) }.keyboardShortcut("[").disabled(workspace?.page != .terminal && workspace?.page != .files)
            Button(L10n.text("下一个分栏")) { workspace?.focusNextPane() }.keyboardShortcut("]").disabled(workspace?.page != .terminal && workspace?.page != .files)
            Button(L10n.text("最大化 / 还原当前分栏")) { workspace?.togglePaneZoom() }.keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(workspace?.page != .terminal && workspace?.page != .files)
            Divider()
            Button(L10n.text("上一个标签")) { workspace?.navigateTerminal(.previous) }.keyboardShortcut("[", modifiers: [.command, .shift]).disabled(workspace?.canNavigateTerminalTabs != true)
            Button(L10n.text("下一个标签")) { workspace?.navigateTerminal(.next) }.keyboardShortcut("]", modifiers: [.command, .shift]).disabled(workspace?.canNavigateTerminalTabs != true)
            Button(L10n.text("上一个标签 · ⌘⌥←")) { workspace?.navigateTerminal(.previous) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(workspace?.canNavigateTerminalTabs != true)
            Button(L10n.text("下一个标签 · ⌘⌥→")) { workspace?.navigateTerminal(.next) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(workspace?.canNavigateTerminalTabs != true)
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? L10n.text("最后一个标签") : L10n.text("切换到标签 \(number)")) { workspace?.navigateTerminal(.number(number)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.command, .option]).disabled(workspace?.canNavigateTerminalTabs != true)
            }
            Button(L10n.text("Agent 会话…")) { workspace?.showAgentSessions = true }.keyboardShortcut("j", modifiers: [.command, .option]).disabled(workspace?.canNavigateTerminalTabs != true)
        }
        CommandMenu(L10n.text("工作区")) {
            Button(L10n.text("常用命令…")) { workspace?.showCommandSnippets = true }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(workspace == nil)
            Button(L10n.text("定位终端当前目录")) { workspace?.openTerminalDirectory() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(workspace?.selectedTerminal == nil)
            Divider()
            Button(L10n.text("展开 / 折叠主机侧栏")) { workspace?.toggleSidebar() }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(workspace == nil)
            ForEach(Array(WorkspacePage.allCases.enumerated()), id: \.element) { index, page in
                Button(page.title) { workspace?.page = page }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
            Button(L10n.text("查找终端内容")) {
                workspace?.showTerminalSearch = true
            }.keyboardShortcut("f")
            Button(L10n.text("增大字体")) { let store = AppStore.shared; store.fontSize = min(28, store.fontSize + 1); store.savePreferences() }.keyboardShortcut("+")
            Button(L10n.text("减小字体")) { let store = AppStore.shared; store.fontSize = max(10, store.fontSize - 1); store.savePreferences() }.keyboardShortcut("-")
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var updater = UpdateController.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Form {
            Section(L10n.text("语言 / Language")) {
                Picker(L10n.text("界面语言"), selection: $store.languagePreference) {
                    Text(L10n.text("跟随系统")).tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Text(L10n.text("选择后立即生效并自动保存，无需重启；不会中断终端、传输或编辑。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("外观")) {
                Picker(L10n.text("配色"), selection: $store.appearance) { Text(L10n.text("跟随系统")).tag("system"); Text(L10n.text("浅色")).tag("light"); Text(L10n.text("深色")).tag("dark") }
                Picker(L10n.text("终端字体"), selection: $store.fontName) { Text(L10n.text("系统等宽字体")).tag("SF Mono"); Text("Menlo").tag("Menlo"); Text("Monaco").tag("Monaco") }
                Slider(value: $store.fontSize, in: 10...28, step: 1) { Text(L10n.text("字号 \(Int(store.fontSize))")) }
            }
            Section(L10n.text("隐私与安全")) {
                Toggle(L10n.text("SSH 异常断线后自动重连"), isOn: $store.automaticallyReconnectSSH)
                Text(L10n.text("保留 SSH 心跳容错，按退避重试；指纹或认证需要确认时暂停，不反复弹密码框，不重放命令。")) .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("后台长任务完成时提醒"), isOn: $store.notifyLongTasks)
                Text(L10n.text("超过 30 秒的传输或明确报告开始/结束的 Shell 命令才提醒；不根据停止输出猜完成，提醒不包含命令正文。")) .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("附件上传后自动插入终端"), isOn: $store.automaticallyInsertAttachments)
                Text(L10n.text("主机可单独覆盖。仅影响新上传；目标变化时仍需确认，永不自动回车。")).font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("tmux 终端右键使用 tmux 菜单"), isOn: $store.useTmuxContextMenu)
                Text(L10n.text("默认使用复制、粘贴等普通菜单。Shift＋右键临时使用普通菜单；仅识别应用附着的 tmux。")).font(.caption).foregroundStyle(.secondary)
                Label(L10n.text("配置和传输记录仅保存在本机"), systemImage: "internaldrive")
                Label(L10n.text("凭据使用 macOS 钥匙串；不包含在主机配置中"), systemImage: "key")
                Picker(L10n.text("终端写入剪贴板"), selection: $store.terminalClipboardWritePolicy) {
                    ForEach(TerminalClipboardWritePolicy.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L10n.text("允许当前终端读取 Mac 文本剪贴板"), isOn: $store.terminalClipboardReadAllowed)
                Text(L10n.text("开启读取后，当前有焦点的本机、SSH 或 tmux 程序可取得剪贴板文本（可能包含密码），不会逐次询问。仅对可信终端开启。图片/文件仍走附件流程。"))
                    .font(.caption).foregroundStyle(store.terminalClipboardReadAllowed ? .orange : .secondary)
                Text(L10n.text("设置立即生效并保存；只允许前台有焦点的终端，后台请求不会读写剪贴板。多行粘贴确认不受此设置影响。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("在 Finder 中显示数据目录")) { NSWorkspace.shared.open(store.paths.root) }
            }
            Section(L10n.text("软件更新")) {
                Toggle(L10n.text("启动时检查 GitHub Release"), isOn: $updater.automaticallyCheck)
                Button(L10n.text("检查更新…")) { openWindow(id: "updates"); updater.check() }
            }
        }.formStyle(.grouped).padding().frame(width: 580, height: 680)
            .onChange(of: store.appearance) { _, _ in store.savePreferences() }
            .onChange(of: store.fontSize) { _, _ in store.savePreferences() }
            .onChange(of: store.fontName) { _, _ in store.savePreferences() }
    }
}
