import AppKit
import SwiftUI
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum EditorChecks {
    final class State: ObservableObject {
        @Published var presented = true
        var saves = 0
        var frames: [String: CGRect] = [:]
    }
    struct Container: View {
        @ObservedObject var state: State
        let document: EditDocument
        let store: AppStore
        let host: HostProfile?
        var body: some View {
            Color.clear.frame(width: 1000, height: 720).sheet(isPresented: $state.presented) {
                RemoteEditor(document: document, host: host, store: store) { state.saves += 1 }
                    .background(Color(nsColor: .windowBackgroundColor))
                    .coordinateSpace(name: "workspace-interactions")
                    .onPreferenceChange(InteractionFrames.self) { state.frames = $0 }
            }
        }
    }
    static func run(store: AppStore, output: URL) async throws {
        try StatusClockChecks.run()
        try await check(store: store, host: nil, output: output)
        if let host = store.hosts.first(where: { $0.address == "127.0.0.1" && [22281, 22282].contains($0.port) }) {
            try await check(store: store, host: host, output: output.deletingPathExtension().appendingPathExtension("ssh.png"))
        }
    }
    private static func check(store: AppStore, host: HostProfile?, output: URL) async throws {
        let path = host == nil ? store.paths.root.appendingPathComponent("editor-check.md").path : "/tmp/farport-editor-\(UUID().uuidString).md"
        let original = "# Editor\n\n中文内容\n"
        let transport = store.transport
        let document = try await Task.detached {
            let client = try transport.files(host); defer { client.close() }
            try client.createFile(path)
            try client.saveText(path, data: Data(original.utf8), expected: client.stat(path), original: Data())
            return EditDocument(file: RemoteFile(name: "editor-check.md", path: path, attributes: try client.stat(path)), data: Data(original.utf8))
        }.value
        func contents() async throws -> String {
            try await Task.detached { let client = try transport.files(host); defer { client.close() }; return String(decoding: try client.preview(path), as: UTF8.self) }.value
        }
        let state = State()
        let content = NSHostingView(rootView: Container(state: state, document: document, store: store, host: host).environment(\.locale, L10n.language.locale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = content; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        try await wait { window.sheets.first != nil }
        guard let sheet = window.sheets.first else { throw WorkbenchError.message("找不到编辑窗口") }
        try await wait { editor(in: sheet.contentView) != nil }
        guard let text = editor(in: sheet.contentView) else { throw WorkbenchError.message("找不到编辑文本框") }
        sheet.makeKeyAndOrderFront(nil); sheet.makeFirstResponder(text)
        try await wait { state.frames["editor.undo"] != nil }
        guard text.undoManager?.canUndo == false else { throw WorkbenchError.message("初始撤销状态错误") }
        text.insertText("第一轮保存\n", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        let first = text.string
        let originalPreference = store.languagePreference
        let originalLanguage = L10n.language
        let previousDefault = L10n.preferenceDefaults.object(forKey: "farport.language")
        let selection = text.selectedRange()
        for language in ["en", "zh-Hans", originalLanguage.rawValue] {
            store.languagePreference = language
            try await Task.sleep(for: .milliseconds(120))
            guard editor(in: sheet.contentView) === text, text.string == first, text.selectedRange() == selection else { throw WorkbenchError.message("语言切换重建编辑器或丢失草稿/选区") }
        }
        store.languagePreference = originalPreference; L10n.setPreference(originalLanguage.rawValue)
        if let previousDefault { L10n.preferenceDefaults.set(previousDefault, forKey: "farport.language") } else { L10n.preferenceDefaults.removeObject(forKey: "farport.language") }
        sheet.makeKeyAndOrderFront(nil); sheet.makeFirstResponder(text)
        try await key("s", code: 1, in: sheet)
        try await wait { state.saves == 1 }
        guard state.presented, sheet.isVisible, try await contents() == first else { throw WorkbenchError.message("Cmd+S 保存后关闭了编辑窗口，或内容未写入") }
        text.insertText("第二轮保存\n", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        let second = text.string
        try await key("s", code: 1, in: sheet)
        try await wait { state.saves == 2 }
        guard state.presented, try await contents() == second else { throw WorkbenchError.message("连续保存失败") }
        try await key("z", code: 6, in: sheet)
        guard text.string == first else { throw WorkbenchError.message("保存后 Cmd+Z 未保留撤销历史") }
        try await key("s", code: 1, in: sheet)
        try await wait { state.saves == 3 }
        guard try await contents() == first else { throw WorkbenchError.message("撤销后保存仍写入旧缓冲区") }
        try await key("z", code: 6, modifiers: [.command, .shift], in: sheet)
        guard text.string == second else { throw WorkbenchError.message("Shift+Cmd+Z 重做失败") }
        try await press("editor.undo", in: sheet, state: state)
        guard text.string == first else { throw WorkbenchError.message("撤销按钮无效") }
        try await press("editor.redo", in: sheet, state: state)
        guard text.string == second else { throw WorkbenchError.message("重做按钮无效") }
        let clipboard = NSPasteboard.general
        let previousClipboard = clipboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            clipboard.clearContents()
            if let previousClipboard { clipboard.writeObjects(previousClipboard.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        try await press("editor.selectAll", in: sheet, state: state)
        guard text.selectedRange().length == second.utf16.count else { throw WorkbenchError.message("全选按钮无效") }
        try await press("editor.copy", in: sheet, state: state)
        guard clipboard.string(forType: .string) == second else { throw WorkbenchError.message("复制按钮无效：选中 \(text.selectedRange().length)，应复制 \(second.utf16.count)，剪贴板 \(clipboard.string(forType: .string)?.utf16.count ?? -1)") }
        try await press("editor.cut", in: sheet, state: state)
        guard text.string.isEmpty else { throw WorkbenchError.message("剪切按钮无效") }
        try await press("editor.paste", in: sheet, state: state)
        guard text.string == second else { throw WorkbenchError.message("粘贴按钮无效") }
        try await press("editor.save", in: sheet, state: state)
        try await wait { state.saves == 4 }
        guard state.presented, try await contents() == second else { throw WorkbenchError.message("工具栏保存失败") }
        try await wait { state.frames["editor.saved"] != nil }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let capture = try ProcessRunner.run(executable: "/usr/sbin/screencapture", arguments: ["-x", "-l", String(sheet.windowNumber), output.path], timeout: 5)
        if capture.status != 0, let view = sheet.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        try await Task.sleep(for: .milliseconds(2200))
        guard state.frames["editor.saved"] == nil, state.presented else { throw WorkbenchError.message("保存轻提示未自动消失") }
        let external = "External change\n"
        try await Task.detached {
            let client = try transport.files(host); defer { client.close() }
            try client.saveText(path, data: Data(external.utf8), expected: client.stat(path), original: Data(second.utf8))
        }.value
        text.insertText("本地待保存修改\n", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        try await key("s", code: 1, in: sheet)
        try await wait { state.frames["editor.error"] != nil && text.isEditable }
        guard state.saves == 4, state.presented, try await contents() == external, text.string.contains("本地待保存修改") else { throw WorkbenchError.message("保存冲突覆盖文件或丢失草稿") }
        try await press("editor.undo", in: sheet, state: state)
        guard text.string == second else { throw WorkbenchError.message("冲突后撤销丢失已保存内容") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if NSApp.modalWindow != nil { NSApp.abortModal() } }
        try await key("\u{1b}", code: 53, modifiers: [], in: sheet)
        try await wait { !state.presented && window.sheets.isEmpty }
        try await Task.detached { let client = try transport.files(host); defer { client.close() }; try client.removeRecursively(path) }.value
        print("PASS · \(host == nil ? "本机" : "隔离 SSH") 编辑器：连续保存、保留窗口、保存后撤销/重做、工具栏剪贴板、轻提示、冲突保留草稿")
    }
    private static func press(_ identifier: String, in window: NSWindow, state: State) async throws {
        guard let frame = state.frames[identifier], let content = window.contentView else { throw WorkbenchError.message("编辑按钮不可用：\(identifier)") }
        let vertical = content.safeAreaInsets.top + frame.midY
        let point = content.convert(NSPoint(x: frame.midX, y: content.isFlipped ? vertical : content.bounds.height - vertical), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { throw WorkbenchError.message("无法创建编辑按钮事件") }
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        try await Task.sleep(for: .milliseconds(200))
    }
    private static func editor(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
    private static func key(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = .command, in window: NSWindow) async throws {
        if let text = editor(in: window.contentView) { window.makeFirstResponder(text) }
        let characters = modifiers.contains(.shift) ? character.uppercased() : character
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { throw WorkbenchError.message("无法创建编辑快捷键事件") }
        if editor(in: window.contentView)?.performKeyEquivalent(with: event) != true { _ = window.performKeyEquivalent(with: event) }
        try await Task.sleep(for: .milliseconds(200))
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw WorkbenchError.message("编辑器回归等待超时：第 \(line) 行") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
