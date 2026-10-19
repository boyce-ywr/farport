import AppKit
import SwiftUI

@MainActor
final class FileEditorBuffer: ObservableObject {
    @Published var text: String
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var hasSelection = false
    let undoManager = UndoManager()
    weak var textView: NSTextView?
    init(text: String) { self.text = text }
    func undo() { textView?.breakUndoCoalescing(); undoManager.undo(); focus() }
    func redo() { textView?.breakUndoCoalescing(); undoManager.redo(); focus() }
    func cut() { textView?.cut(nil); focus() }
    func copy() { textView?.copy(nil); focus() }
    func paste() { textView?.pasteAsPlainText(nil); focus() }
    func selectAll() { textView?.selectAll(nil); focus() }
    func restoreDraft(_ value: String) {
        guard let textView else { text = value; return }
        textView.breakUndoCoalescing()
        textView.insertText(value, replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
        updateActions(); focus()
    }
    func focus() { if let textView { textView.window?.makeFirstResponder(textView) } }
    func updateActions() {
        if let textView, text != textView.string { text = textView.string }
        canUndo = undoManager.canUndo; canRedo = undoManager.canRedo
        hasSelection = (textView?.selectedRange().length ?? 0) > 0
    }
}

struct FileEditorTextView: NSViewRepresentable {
    @ObservedObject var buffer: FileEditorBuffer
    let editable: Bool
    func makeCoordinator() -> Coordinator { Coordinator(buffer: buffer) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let text = EditorTextView(frame: scroll.bounds)
        text.isRichText = false; text.allowsUndo = true; text.isEditable = editable
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.string = buffer.text; text.delegate = context.coordinator
        buffer.textView = text; scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        text.isEditable = editable
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? NSTextView)?.delegate = nil
        coordinator.buffer.undoManager.removeAllActions(); coordinator.buffer.textView = nil
    }
    final class EditorTextView: NSTextView {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            if event.charactersIgnoringModifiers?.lowercased() == "z", modifiers == .command || modifiers == [.command, .shift] {
                guard isEditable else { return true }
                breakUndoCoalescing()
                if modifiers.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let buffer: FileEditorBuffer
        init(buffer: FileEditorBuffer) {
            self.buffer = buffer
            super.init()
            for name: Notification.Name in [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup] {
                NotificationCenter.default.addObserver(self, selector: #selector(updateActions), name: name, object: buffer.undoManager)
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        func undoManager(for view: NSTextView) -> UndoManager? { buffer.undoManager }
        func textDidChange(_ notification: Notification) {
            buffer.updateActions()
        }
        func textViewDidChangeSelection(_ notification: Notification) { buffer.updateActions() }
        @objc private func updateActions() { buffer.updateActions() }
    }
}
