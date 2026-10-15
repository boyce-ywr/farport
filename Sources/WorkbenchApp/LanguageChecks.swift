import AppKit
import SwiftUI
import WorkbenchCore
import Observation

@MainActor
enum LanguageChecks {
    static func run(workspace: Workspace, output: URL) async throws {
        let store = workspace.store
        guard L10n.language == .english, !L10n.translations.isEmpty else { throw WorkbenchError.message("英文资源未加载") }
        let before = L10n.preferenceDefaults.object(forKey: "farport.language")
        let originalPreference = store.languagePreference
        let originalLanguage = L10n.language
        defer {
            store.languagePreference = originalPreference; L10n.setPreference(originalLanguage.rawValue)
            if let before { L10n.preferenceDefaults.set(before, forKey: "farport.language") }
            else { L10n.preferenceDefaults.removeObject(forKey: "farport.language") }
        }
        workspace.connectLocal()
        guard let terminal = workspace.selectedTerminal else { throw WorkbenchError.message("没有测试终端") }
        for _ in 0..<100 { if terminal.connected { break }; try await Task.sleep(for: .milliseconds(50)) }
        guard terminal.connected else { throw WorkbenchError.message("测试终端未启动") }
        let connection = terminal.connectionID
        let observedChange = CancellationFlag()
        withObservationTracking { _ = L10n.text("保存") } onChange: { observedChange.cancel() }
        store.languagePreference = "zh-Hans"
        guard observedChange.isCancelled, L10n.preferenceDefaults.string(forKey: "farport.language") == "zh-Hans", L10n.language == .simplifiedChinese, L10n.text("保存") == "保存", terminal.state == "运行中" else { throw WorkbenchError.message("选择简体中文后未立即切换语言") }
        store.languagePreference = "en"
        guard L10n.language == .english, L10n.text("保存") == "Save", terminal.state == "Running" else { throw WorkbenchError.message("选择英文后未立即切换语言") }
        let content = NSHostingView(rootView: PreferencesView(store: store).environment(\.locale, L10n.language.locale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 570), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Farport Settings"; window.contentView = content; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500)); window.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw WorkbenchError.message("无法截图英文设置") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        window.orderOut(nil)
        guard terminal.connectionID == connection, terminal.connected, terminal.terminal.process.running, workspace.selectedTerminal === terminal else { throw WorkbenchError.message("语言切换重建或中断了终端") }
        workspace.close(terminal)
        print("PASS · 语言立即切换、观察通知、偏好保存、现有终端状态翻译；终端连接和实例不变")
    }
}
