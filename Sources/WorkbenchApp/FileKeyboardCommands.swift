import SwiftUI
import AppKit

struct FileKeyboardCommands: NSViewRepresentable {
    let model: FileModel
    let focused: Bool
    let visible: Bool
    let focus: () -> Void
    let copy: () -> Void
    let paste: () -> Void
    let selectAll: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = Anchor(); context.coordinator.view = view
        view.updated = { [weak coordinator = context.coordinator] in
            DispatchQueue.main.async { coordinator?.bindTable() }
        }
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return event }
            return coordinator.handle(event)
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model; coordinator.focused = focused; coordinator.visible = visible; coordinator.focus = focus
        coordinator.copy = copy; coordinator.paste = paste; coordinator.selectAll = selectAll
        DispatchQueue.main.async { [weak coordinator] in coordinator?.bindTable() }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }; coordinator.monitor = nil }
    final class Anchor: NSView {
        var updated: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true; updated?() }
        override func layout() { super.layout(); updated?() }
        override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(point); updated?() }
    }
    @MainActor final class Coordinator {
        weak var view: NSView?
        weak var model: FileModel?
        var monitor: Any?
        var focused = false
        var visible = false
        var lastFocusRequest: UInt64 = 0
        var focus: (() -> Void)?
        var copy: (() -> Void)?
        var paste: (() -> Void)?
        var selectAll: (() -> Void)?
        private func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
        func bindTable() {
            guard let view, let window = view.window, let model else { return }
            let point = view.convert(NSPoint.zero, to: nil)
            var ancestor = view.superview
            while let current = ancestor {
                let matches = tables(in: current).filter { table in
                    guard let scroll = table.enclosingScrollView else { return false }
                    return scroll.convert(scroll.bounds, to: nil).contains(point)
                }
                if matches.count == 1 { model.tableView = matches[0]; break }
                ancestor = current.superview
            }
            if visible, focused, model.focusRequest != lastFocusRequest, let table = model.tableView,
               window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
               !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) {
                if window.makeFirstResponder(table) { lastFocusRequest = model.focusRequest }
            }
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard visible, let view, !view.isHiddenOrHasHiddenAncestor, let window = view.window,
                  window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
                  event.window === window || (event.window == nil && NSApp.keyWindow === window) else { return event }
            bindTable()
            guard let table = model?.tableView, table.window === window else { return event }
            if event.type == .leftMouseDown {
                if let scroll = table.enclosingScrollView, scroll.convert(scroll.bounds, to: nil).contains(event.locationInWindow) { focus?() }
                return event
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            guard modifiers == .command, !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return event }
            if let responder = window.firstResponder as? NSView {
                var current: NSView? = responder
                while let candidate = current, !(candidate is NSTableView) { current = candidate.superview }
                guard current === table else { return event }
            } else if !focused || (window.firstResponder != nil && window.firstResponder !== window) { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": focus?(); copy?()
            case "v": focus?(); paste?()
            case "a": focus?(); selectAll?()
            default: return event
            }
            return nil
        }
    }
}
