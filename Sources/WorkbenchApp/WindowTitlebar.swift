import AppKit
import SwiftUI

struct WindowTitlebar: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero); context.coordinator.anchor = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return event }; return coordinator.handle(event)
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }; coordinator.monitor = nil
    }
    @MainActor final class Coordinator {
        weak var anchor: NSView?
        var monitor: Any?
        private var restoredFrame: NSRect?
        private var consumeMouseUp = false
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = anchor?.window, event.window === window else { return event }
            if event.type == .leftMouseUp && consumeMouseUp { consumeMouseUp = false; return nil }
            guard event.type == .leftMouseDown, event.clickCount == 2,
                  !window.styleMask.contains(.fullScreen), window.attachedSheet == nil,
                  Self.isTitlebar(event.locationInWindow, window: window) else { return event }
            toggle(window); consumeMouseUp = true
            return nil
        }
        static func isTitlebar(_ point: NSPoint, window: NSWindow) -> Bool {
            let height = window.frame.height
            let boundary = min(window.contentLayoutRect.maxY, height - 28)
            guard point.y >= boundary, point.y < height, point.x >= 0, point.x < window.frame.width else { return false }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(kind), button.convert(button.bounds, to: nil).insetBy(dx: -5, dy: -5).contains(point) { return false }
            }
            return true
        }
        func toggle(_ window: NSWindow) {
            guard let screen = window.screen else { return }
            let available = screen.visibleFrame; let current = window.frame
            let filled = abs(current.minX - available.minX) < 2 && abs(current.minY - available.minY) < 2 && abs(current.width - available.width) < 2 && abs(current.height - available.height) < 2
            if filled, var restored = restoredFrame {
                restored.size.width = min(restored.width, available.width); restored.size.height = min(restored.height, available.height)
                restored.origin.x = min(max(restored.minX, available.minX), available.maxX - restored.width)
                restored.origin.y = min(max(restored.minY, available.minY), available.maxY - restored.height)
                window.setFrame(restored, display: true, animate: false); restoredFrame = nil
            } else if filled { window.zoom(nil) }
            else { restoredFrame = current; window.setFrame(available, display: true, animate: false) }
        }
    }
}
