import SwiftUI
import AppKit
import Darwin

@main
struct SSHWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var store = AppStore.shared
    init() { signal(SIGPIPE, SIG_IGN) }
    var body: some Scene {
        WindowGroup("栖远 Farport", id: "workspace") {
            WorkspaceRoot(store: store)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(store.colorScheme)
                .tint(.teal)
        }
        .defaultSize(width: 1360, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands { WorkbenchCommands() }
        Settings { PreferencesView(store: store) }
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = AppStore.shared
        if store.activeCount > 0 && ProcessInfo.processInfo.environment["SWB_QA_EXIT"] != "1" {
            let alert = NSAlert(); alert.messageText = "暂停传输并退出？"; alert.informativeText = "未完成的任务会保留断点。SSH 连接将关闭；远端 tmux 会话不会因此被结束。"; alert.addButton(withTitle: "暂停并退出"); alert.addButton(withTitle: "取消")
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
            Button("关于栖远 Farport") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "栖远 Farport",
                    .applicationVersion: "0.1.1",
                    .credits: NSAttributedString(string: "连接远方，安放工作。\n\n原生 SSH · tmux 工作区 · 远程文件传输")
                ])
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") { openWindow(id: "workspace") }.keyboardShortcut("n")
            Button("新建 SSH 终端") { if let workspace, let host = workspace.host { workspace.connect(host) } }.keyboardShortcut("t").disabled(workspace?.host == nil)
            Button("分屏终端") { if let workspace, let host = workspace.host { workspace.connect(host, split: true) } }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(workspace?.host == nil)
        }
        CommandMenu("工作区") {
            ForEach(Array(WorkspacePage.allCases.enumerated()), id: \.element) { index, page in
                Button(page.rawValue) { workspace?.page = page }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
            Button("查找终端内容") {
                let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                workspace?.selectedTerminal?.terminal.performFindPanelAction(item)
            }.keyboardShortcut("f")
            Button("增大字体") { let store = AppStore.shared; store.fontSize = min(28, store.fontSize + 1); store.savePreferences() }.keyboardShortcut("+")
            Button("减小字体") { let store = AppStore.shared; store.fontSize = max(10, store.fontSize - 1); store.savePreferences() }.keyboardShortcut("-")
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Form {
            Section("外观") {
                Picker("配色", selection: $store.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                Picker("终端字体", selection: $store.fontName) { Text("系统等宽字体").tag("SF Mono"); Text("Menlo").tag("Menlo"); Text("Monaco").tag("Monaco") }
                Slider(value: $store.fontSize, in: 10...28, step: 1) { Text("字号 \(Int(store.fontSize))") }
            }
            Section("隐私与安全") {
                Label("配置和传输记录仅保存在本机", systemImage: "internaldrive")
                Label("凭据使用 macOS 钥匙串；不包含在主机配置中", systemImage: "key")
                Label("拒绝远端读取剪贴板；多行粘贴需要确认", systemImage: "lock.shield")
                Button("在 Finder 中显示数据目录") { NSWorkspace.shared.open(store.paths.root) }
            }
        }.formStyle(.grouped).padding().frame(width: 520, height: 360)
            .onChange(of: store.appearance) { _, _ in store.savePreferences() }
            .onChange(of: store.fontSize) { _, _ in store.savePreferences() }
            .onChange(of: store.fontName) { _, _ in store.savePreferences() }
    }
}
