import AppKit
import SwiftUI

@MainActor
final class TabPointerState: ObservableObject {
    @Published var dragging: UUID?
    @Published var target: UUID?
    final class Anchor {
        weak var view: NSView?
        var frame: CGRect
        init(_ view: NSView, frame: CGRect) { self.view = view; self.frame = frame }
    }
    var anchors: [UUID: Anchor] = [:]
    func pointInWorkspace(_ point: NSPoint, window: NSWindow) -> NSPoint? {
        guard let content = window.contentView else { return nil }
        let local = content.convert(point, from: nil)
        return NSPoint(x: local.x, y: (content.isFlipped ? local.y : content.bounds.height - local.y) - content.safeAreaInsets.top)
    }
    func target(at point: NSPoint, window: NSWindow) -> UUID? {
        guard let local = pointInWorkspace(point, window: window) else { return nil }
        return anchors.first { _, anchor in
            guard let view = anchor.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            if let clip = view.enclosingScrollView?.contentView, !clip.visibleRect.contains(clip.convert(point, from: nil)) { return false }
            return anchor.frame.contains(local)
        }?.key
    }
}

struct TabPointerRegion: NSViewRepresentable {
    let identifier: UUID
    let state: TabPointerState
    let frame: CGRect
    let select: () -> Void
    let move: (UUID, UUID) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero); context.coordinator.anchor = view
        state.anchors[identifier] = TabPointerState.Anchor(view, frame: frame)
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return event }; return coordinator.handle(event)
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.region = self; state.anchors[identifier]?.frame = frame }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.region.state.anchors.removeValue(forKey: coordinator.region.identifier)
        coordinator.reset()
    }
    @MainActor final class Coordinator {
        var region: TabPointerRegion
        weak var anchor: NSView?
        var monitor: Any?
        private var origin: NSPoint?
        private var moved = false
        init(_ region: TabPointerRegion) { self.region = region }
        func reset() {
            if origin != nil { region.state.dragging = nil; region.state.target = nil }
            origin = nil; moved = false
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let anchor, let window = anchor.window else { return event }
            if origin != nil, event.type == .keyDown, event.keyCode == 53 { reset(); return nil }
            if origin != nil, event.type == .leftMouseUp {
                let target = event.window === window ? region.state.target(at: event.locationInWindow, window: window) : nil
                let shouldMove = moved; reset()
                if let target {
                    if shouldMove { if target != region.identifier { region.move(region.identifier, target) } }
                    else if target == region.identifier { region.select() }
                }
                return nil
            }
            guard event.window === window, !anchor.isHiddenOrHasHiddenAncestor else { return event }
            if event.type == .leftMouseDown, region.state.target(at: event.locationInWindow, window: window) == region.identifier {
                origin = event.locationInWindow; moved = false; return nil
            }
            if event.type == .leftMouseDragged, let origin {
                if hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 5 { moved = true }
                if moved {
                    region.state.dragging = region.identifier
                    region.state.target = region.state.target(at: event.locationInWindow, window: window)
                    if let scroll = anchor.enclosingScrollView, let document = scroll.documentView {
                        let point = scroll.contentView.convert(event.locationInWindow, from: nil)
                        let bounds = scroll.contentView.bounds
                        let offset: CGFloat = point.x < bounds.minX + 24 ? -18 : (point.x > bounds.maxX - 24 ? 18 : 0)
                        if offset != 0 { document.scroll(NSPoint(x: max(0, min(document.bounds.width - bounds.width, bounds.minX + offset)), y: bounds.minY)) }
                    }
                }
                return nil
            }
            return event
        }
    }
}
