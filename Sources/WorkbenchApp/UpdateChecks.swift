import AppKit
import SwiftUI
import WorkbenchCore

@MainActor
enum UpdateChecks {
    static func run(output: URL) async throws {
        let updater = UpdateController.shared
        updater.check()
        let deadline = Date().addingTimeInterval(45)
        while updater.checking {
            guard Date() < deadline else { throw WorkbenchError.message("更新检查 UI 超时") }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let error = updater.errorMessage { throw WorkbenchError.message(error) }
        let view = NSHostingView(rootView: UpdateView(updater: updater).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Farport 软件更新"; window.contentView = view; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        window.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw WorkbenchError.message("无法捕获更新窗口") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        window.orderOut(nil)
        print("PASS · 私有 Release 检查 UI：\(updater.message)")
    }
}
