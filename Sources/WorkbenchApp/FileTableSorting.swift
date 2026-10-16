import AppKit
import SwiftUI

struct TableHeaderSorting: NSViewRepresentable {
    let titles: [String]
    let clicked: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(titles: titles, clicked: clicked) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero); context.coordinator.anchor = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return event }; return coordinator.handle(event)
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.titles = titles; context.coordinator.clicked = clicked }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }; coordinator.monitor = nil
    }
    final class Coordinator {
        weak var anchor: NSView?
        var monitor: Any?
        var titles: [String]
        var clicked: (Int) -> Void
        private var pressed: (column: Int, title: String, point: NSPoint)?
        init(titles: [String], clicked: @escaping (Int) -> Void) { self.titles = titles; self.clicked = clicked }
        private func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let table = findTable(child) { return table } }
            return nil
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let anchor, anchor.window === event.window, !anchor.isHiddenOrHasHiddenAncestor else { return event }
            var ancestor: NSView? = anchor.superview
            var table: NSTableView?
            while let view = ancestor { if let found = findTable(view) { table = found; break }; ancestor = view.superview }
            guard let table, let header = table.headerView else { return event }
            let point = header.convert(event.locationInWindow, from: nil)
            let index = header.column(at: point)
            if event.type == .leftMouseUp, let pressed {
                self.pressed = nil
                if header.visibleRect.contains(point), index >= 0, index < table.tableColumns.count,
                   table.tableColumns[index].title == pressed.title, abs(point.x - pressed.point.x) < 5, abs(point.y - pressed.point.y) < 5 { clicked(pressed.column) }
                return nil
            }
            guard header.visibleRect.contains(point), index >= 0, index < table.tableColumns.count,
                  let column = titles.firstIndex(of: table.tableColumns[index].title) else { return event }
            let rect = header.headerRect(ofColumn: index)
            guard point.x - rect.minX > 5, rect.maxX - point.x > 5 else { return event }
            guard event.type == .leftMouseDown else { return event }
            pressed = (column, titles[column], point)
            return nil
        }
    }
}
