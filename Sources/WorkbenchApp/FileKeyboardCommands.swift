import SwiftUI
import AppKit

struct FileKeyboardCommands: NSViewRepresentable {
    let copy: () -> Void
    let paste: () -> Void
    let selectAll: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let window = coordinator.view?.window, event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let responder = window.firstResponder as? NSView else { return event }
            var current: NSView? = responder
            while let view = current, !(view is NSTableView) { current = view.superview }
            guard current is NSTableView else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": coordinator.copy?()
            case "v": coordinator.paste?()
            case "a": coordinator.selectAll?()
            default: return event
            }
            return nil
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.copy = copy; context.coordinator.paste = paste; context.coordinator.selectAll = selectAll }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }; coordinator.monitor = nil }
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var copy: (() -> Void)?
        var paste: (() -> Void)?
        var selectAll: (() -> Void)?
    }
}
