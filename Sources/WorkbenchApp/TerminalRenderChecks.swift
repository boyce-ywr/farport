import AppKit
import Foundation

@MainActor
enum TerminalRenderChecks {
    static func run(output: URL) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = SafeTerminalView(frame: NSRect(x: 0, y: 0, width: 1050, height: 340))
        terminal.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.075, alpha: 1)
        terminal.nativeForegroundColor = NSColor(srgbRed: 0.85, green: 0.88, blue: 0.90, alpha: 1)
        window.contentView = terminal
        window.orderFront(nil)
        let text = "当前目标是完成终端渲染验证，中文与 English、空格正常显示，不应该出现白色方块。"
        terminal.feed(text: "\u{1b}[?25l\u{1b}[2J\u{1b}[H普通：\(text)\r\n\r\n\u{1b}[2;3mRecap: \(text)\u{1b}[0m\r\n\r\n\u{1b}[3m斜体：\(text)\u{1b}[0m\r\n\r\n\u{1b}[2m暗色：\(text)\u{1b}[0m\r\n\r\n合法块字符：█ ▄ ▀ ▌ ▐ ░ ▒ ▓\r\n")
        terminal.displayIfNeeded()
        guard let bitmap = terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds) else { throw CocoaError(.fileWriteUnknown) }
        terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
        if let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
            context.saveGState(); context.setBlendMode(.destinationOver); context.setFillColor(terminal.nativeBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)); context.restoreGState()
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        print("终端渲染最小复现：\(output.lastPathComponent)")
        window.orderOut(nil)
    }
}
