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
        if store.activeCount > 0 && ProcessInfo.processInfo.environment["SWB_QA_EXIT"] != "1" {
            let alert = NSAlert(); alert.messageText = L10n.text("暂停传输并退出？"); alert.informativeText = L10n.text("未完成的任务会保留断点。SSH 连接将关闭；远端 tmux 会话不会因此被结束。"); alert.addButton(withTitle: L10n.text("暂停并退出")); alert.addButton(withTitle: L10n.text("取消"))
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
            Button(L10n.text("左右分栏")) { workspace?.newTerminal(split: true) }.keyboardShortcut("d").disabled(workspace?.page != .terminal)
            Button(L10n.text("上下分栏")) { workspace?.newTerminal(split: true, axis: .topBottom) }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(workspace?.page != .terminal)
        }
        CommandGroup(after: .appInfo) {
            Button(L10n.text("检查更新…")) { openWindow(id: "updates"); UpdateController.shared.check() }
        }
        CommandMenu(L10n.text("终端")) {
            Button(L10n.text("上一个分栏")) { workspace?.focusNextPane(backward: true) }.keyboardShortcut("[").disabled(workspace?.page != .terminal)
            Button(L10n.text("下一个分栏")) { workspace?.focusNextPane() }.keyboardShortcut("]").disabled(workspace?.page != .terminal)
            Button(L10n.text("最大化 / 还原当前分栏")) { workspace?.togglePaneZoom() }.keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(workspace?.page != .terminal)
            Divider()
            Button(L10n.text("上一个标签")) { workspace?.selectNextTab(backward: true) }.keyboardShortcut("[", modifiers: [.command, .shift]).disabled(workspace?.page != .terminal)
            Button(L10n.text("下一个标签")) { workspace?.selectNextTab() }.keyboardShortcut("]", modifiers: [.command, .shift]).disabled(workspace?.page != .terminal)
        }
        CommandMenu(L10n.text("工作区")) {
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
                Text(L10n.text("下次启动生效。请先保存工作并自行重启，当前 SSH 和传输不会被自动中断。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("外观")) {
                Picker(L10n.text("配色"), selection: $store.appearance) { Text(L10n.text("跟随系统")).tag("system"); Text(L10n.text("浅色")).tag("light"); Text(L10n.text("深色")).tag("dark") }
                Picker(L10n.text("终端字体"), selection: $store.fontName) { Text(L10n.text("系统等宽字体")).tag("SF Mono"); Text("Menlo").tag("Menlo"); Text("Monaco").tag("Monaco") }
                Slider(value: $store.fontSize, in: 10...28, step: 1) { Text(L10n.text("字号 \(Int(store.fontSize))")) }
            }
            Section(L10n.text("隐私与安全")) {
                Label(L10n.text("配置和传输记录仅保存在本机"), systemImage: "internaldrive")
                Label(L10n.text("凭据使用 macOS 钥匙串；不包含在主机配置中"), systemImage: "key")
                Label(L10n.text("拒绝远端读取剪贴板；多行粘贴需要确认"), systemImage: "lock.shield")
                Button(L10n.text("在 Finder 中显示数据目录")) { NSWorkspace.shared.open(store.paths.root) }
            }
            Section(L10n.text("软件更新")) {
                Toggle(L10n.text("启动时检查 GitHub Release"), isOn: $updater.automaticallyCheck)
                Button(L10n.text("检查更新…")) { openWindow(id: "updates"); updater.check() }
            }
        }.formStyle(.grouped).padding().frame(width: 560, height: 570)
            .onChange(of: store.appearance) { _, _ in store.savePreferences() }
            .onChange(of: store.fontSize) { _, _ in store.savePreferences() }
            .onChange(of: store.fontName) { _, _ in store.savePreferences() }
    }
}
