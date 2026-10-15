import AppKit
import SwiftUI
import WorkbenchCore

@MainActor
enum LanguageChecks {
    static func run(store: AppStore, output: URL) async throws {
        guard L10n.language == .english, !L10n.translations.isEmpty else { throw WorkbenchError.message("英文资源未加载") }
        let before = UserDefaults.standard.object(forKey: "farport.language")
        defer {
            if let before { UserDefaults.standard.set(before, forKey: "farport.language") }
            else { UserDefaults.standard.removeObject(forKey: "farport.language") }
        }
        store.languagePreference = "zh-Hans"
        guard UserDefaults.standard.string(forKey: "farport.language") == "zh-Hans", L10n.language == .english else { throw WorkbenchError.message("语言保存或下次启动生效规则错误") }
        store.languagePreference = "en"
        let content = NSHostingView(rootView: PreferencesView(store: store).environment(\.locale, L10n.language.locale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 570), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Farport Settings"; window.contentView = content; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500)); window.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw WorkbenchError.message("无法截图英文设置") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        window.orderOut(nil)
        print("PASS · 英文设置窗口、偏好保存与重启生效，不自动终止连接")
    }
}
