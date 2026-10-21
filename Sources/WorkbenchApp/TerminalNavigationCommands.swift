import AppKit
import SwiftUI
import WorkbenchCore

struct TerminalNavigationCommands: NSViewRepresentable {
    let workspace: Workspace
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown]) { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return event }; return coordinator.handle(event)
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.workspace = workspace }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
    @MainActor final class Coordinator {
        weak var view: NSView?
        weak var workspace: Workspace?
        var monitor: Any?
        var consumed: Set<UInt16> = []
        private var pendingModifiers: [NSEvent] = []
        private weak var modifierTarget: SafeTerminalView?
        private var suppressModifiers = false
        private func flushModifiers() {
            if let modifierTarget, modifierTarget.window?.firstResponder === modifierTarget {
                for event in pendingModifiers { modifierTarget.flagsChanged(with: event) }
            }
            pendingModifiers = []; modifierTarget = nil
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            if event.type == .keyUp, consumed.remove(event.keyCode) != nil { return nil }
            guard let window = view?.window, event.window === window || (event.window == nil && NSApp.keyWindow === window) else { return event }
            if event.type == .flagsChanged {
                let held = event.modifierFlags.intersection([.command, .option, .shift])
                if suppressModifiers {
                    if held.isEmpty { suppressModifiers = false }
                    return nil
                }
                if workspace?.canNavigateTerminalTabs == true, !event.modifierFlags.contains(.control),
                   !held.isEmpty || !pendingModifiers.isEmpty {
                    if modifierTarget == nil { modifierTarget = workspace?.selectedTerminal?.terminal }
                    pendingModifiers.append(event)
                    if held.isEmpty { flushModifiers() }
                    return nil
                }
                flushModifiers(); return event
            }
            if event.type == .leftMouseDown { flushModifiers(); return event }
            guard event.type == .keyDown else { return event }
            if consumed.contains(event.keyCode), !event.isARepeat { consumed.remove(event.keyCode) }
            guard let workspace, workspace.canNavigateTerminalTabs,
                  let action = TerminalNavigationAction.resolve(keyCode: event.keyCode, text: event.charactersIgnoringModifiers ?? "",
                                                                 command: event.modifierFlags.contains(.command), option: event.modifierFlags.contains(.option),
                                                                 control: event.modifierFlags.contains(.control), shift: event.modifierFlags.contains(.shift)) else {
                if consumed.contains(event.keyCode) { return nil }
                flushModifiers(); return event
            }
            pendingModifiers = []; modifierTarget = nil; suppressModifiers = true
            consumed.insert(event.keyCode); workspace.navigateTerminal(action); return nil
        }
    }
}

extension Workspace {
    var canNavigateTerminalTabs: Bool {
        guard page == .terminal, NSApp.isActive, let terminal = selectedTerminal?.terminal, let window = terminal.window,
              window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
              window.firstResponder === terminal, !terminal.hasMarkedText() else { return false }
        return true
    }
    func navigateTerminal(_ action: TerminalNavigationAction) {
        guard canNavigateTerminalTabs else { return }
        switch action {
        case .previous: selectNextTab(backward: true)
        case .next: selectNextTab()
        case .number(let number):
            let index = number == 9 ? layout.tabs.count - 1 : number - 1
            if layout.tabs.indices.contains(index) { chooseTerminalTab(layout.tabs[index].id) }
        case .agents: showAgentSessions = true
        }
    }
}
