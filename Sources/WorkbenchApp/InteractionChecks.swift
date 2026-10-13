import SwiftUI
import AppKit

struct InteractionFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, latest in latest }) }
}

extension View {
    func interactionFrame(_ identifier: String) -> some View {
        background {
            if ProcessInfo.processInfo.environment["SWB_QA_INTERACTIONS"] == "1" || ProcessInfo.processInfo.environment["SWB_QA_SCREEN"] == "file-switching" {
                GeometryReader { geometry in Color.clear.preference(key: InteractionFrames.self, value: [identifier: geometry.frame(in: .named("workspace-interactions"))]) }
            }
        }
    }
}

@MainActor
func clickInterface(_ frame: CGRect, window: NSWindow, xFraction: CGFloat = 0.5, yFraction: CGFloat = 0.5) async {
    guard let content = window.contentView else { return }
    let vertical = content.safeAreaInsets.top + frame.minY + frame.height * yFraction
    let point = content.convert(NSPoint(x: frame.minX + frame.width * xFraction, y: content.isFlipped ? vertical : content.bounds.height - vertical), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(for: .milliseconds(80))
        }
    }
    try? await Task.sleep(for: .milliseconds(250))
}
