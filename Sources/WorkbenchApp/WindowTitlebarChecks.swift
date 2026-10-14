import AppKit
import Foundation
import WorkbenchCore

@MainActor
enum WindowTitlebarChecks {
    static func run(workspace: Workspace) async throws {
        workspace.connectLocal()
        try await wait { workspace.selectedTerminal?.connected == true }
        guard let window = workspace.selectedTerminal?.terminal.window, let screen = window.screen else { throw WorkbenchError.message("未找到工作台窗口和屏幕") }
        let available = screen.visibleFrame
        let initial = NSRect(x: available.minX + 40, y: available.minY + 40, width: min(1100, available.width - 80), height: min(760, available.height - 80))
        window.setFrame(initial, display: true)
        let restored = window.frame
        window.makeKeyAndOrderFront(nil)
        let sessionID = workspace.selectedTerminalID
        for _ in 0..<2 {
            await doubleClick(window)
            try await wait { close(window.frame, available) }
            guard !window.styleMask.contains(.fullScreen), workspace.selectedTerminalID == sessionID else { throw WorkbenchError.message("最大化进入全屏或改变终端") }
            await doubleClick(window)
            try await wait { close(window.frame, restored) }
        }
        guard !WindowTitlebar.Coordinator.isTitlebar(NSPoint(x: window.frame.width / 2, y: window.frame.height / 2), window: window) else { throw WorkbenchError.message("正文区域被当成标题栏") }
        if let button = window.standardWindowButton(.closeButton) {
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            guard !WindowTitlebar.Coordinator.isTitlebar(center, window: window) else { throw WorkbenchError.message("窗口控制按钮被拦截") }
        }
        await doubleClick(window)
        try await wait { close(window.frame, available) }
        print("PASS · 顶部原生双击填满当前屏幕可用区、两轮恢复原位、不进入全屏、不拦截正文及控制按钮")
    }
    private static func doubleClick(_ window: NSWindow) async {
        let point = NSPoint(x: window.frame.width / 2, y: window.frame.height - 12)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 2, pressure: 1) {
                NSApp.postEvent(event, atStart: false); try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private static func close(_ left: NSRect, _ right: NSRect) -> Bool {
        abs(left.minX - right.minX) < 2 && abs(left.minY - right.minY) < 2 && abs(left.width - right.width) < 2 && abs(left.height - right.height) < 2
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(15)
        while !condition() { guard Date() < end else { throw WorkbenchError.message("标题栏双击验证超时") }; try await Task.sleep(for: .milliseconds(80)) }
    }
}
