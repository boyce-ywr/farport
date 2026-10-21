import AppKit
import SwiftTerm
import WorkbenchCore

@MainActor
private final class ClipboardProtocolProbe: @preconcurrency TerminalDelegate {
    let clipboard = TerminalClipboardState()
    var response = Data()
    var interactive = true
    var prompts = 0
    func send(source: Terminal, data: ArraySlice<UInt8>) { response.append(contentsOf: data) }
    func clipboardRead(source: Terminal) -> Data? { clipboard.read(interactive: interactive) }
    func clipboardCopy(source: Terminal, content: Data) {
        clipboard.receive(content, interactive: interactive) { self.prompts += 1; return false }
    }
}

@MainActor
enum ClipboardPolicyChecks {
    static func run(store: AppStore) throws {
        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        let oldWrite = store.terminalClipboardWritePolicy
        let oldRead = store.terminalClipboardReadAllowed
        let preferenceWrite = UserDefaults.standard.object(forKey: "terminalClipboardWritePolicy")
        let preferenceRead = UserDefaults.standard.object(forKey: "terminalClipboardReadAllowed")
        defer {
            store.terminalClipboardWritePolicy = oldWrite; store.terminalClipboardReadAllowed = oldRead
            if let preferenceWrite { UserDefaults.standard.set(preferenceWrite, forKey: "terminalClipboardWritePolicy") } else { UserDefaults.standard.removeObject(forKey: "terminalClipboardWritePolicy") }
            if let preferenceRead { UserDefaults.standard.set(preferenceRead, forKey: "terminalClipboardReadAllowed") } else { UserDefaults.standard.removeObject(forKey: "terminalClipboardReadAllowed") }
            board.clearContents()
            if let previous { board.writeObjects(previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }) }
        }
        guard TerminalClipboardWritePolicy(stored: nil) == .ask, TerminalClipboardWritePolicy(stored: "invalid") == .ask else { throw WorkbenchError.message("剪贴板默认策略不安全") }
        let probe = ClipboardProtocolProbe()
        probe.clipboard.writePolicy = { store.terminalClipboardWritePolicy }
        probe.clipboard.readAllowed = { store.terminalClipboardReadAllowed }
        let terminal = Terminal(delegate: probe)
        store.terminalClipboardWritePolicy = .ask; store.terminalClipboardReadAllowed = false
        board.clearContents(); board.setString("original", forType: .string)
        func write(_ text: String) { terminal.feed(text: "\u{1b}]52;c;" + Data(text.utf8).base64EncodedString() + "\u{7}") }
        write("denied"); write("again")
        guard probe.prompts == 1, board.string(forType: .string) == "original" else { throw WorkbenchError.message("询问策略没有保留拒绝") }
        store.terminalClipboardWritePolicy = .allow
        write("允许 中文😀")
        probe.clipboard.resetPermission(); write("after reconnect")
        guard probe.prompts == 1, board.string(forType: .string) == "after reconnect" else { throw WorkbenchError.message("始终允许写入仍然询问或重连后丢失策略") }
        probe.clipboard.denyRemoteCopy(); write("blocked locally")
        guard board.string(forType: .string) == "after reconnect" else { throw WorkbenchError.message("单终端禁止失效") }
        probe.clipboard.allowRemoteCopy()
        probe.interactive = false; write("background")
        guard board.string(forType: .string) == "blocked locally" else { throw WorkbenchError.message("后台终端绕过设置写入") }
        probe.interactive = true
        store.terminalClipboardWritePolicy = .deny
        write("global deny"); probe.clipboard.allowRemoteCopy()
        guard board.string(forType: .string) == "blocked locally" else { throw WorkbenchError.message("全局禁止被菜单绕过") }
        probe.response = Data()
        terminal.feed(text: "\u{1b}]52;c;?\u{7}")
        guard probe.response.isEmpty else { throw WorkbenchError.message("默认读取权限未拒绝") }
        store.terminalClipboardReadAllowed = true
        board.clearContents(); board.setString("READ 中文😀", forType: .string)
        terminal.feed(text: "\u{1b}]52;c;?\u{7}")
        guard String(data: probe.response, encoding: .utf8)?.contains(Data("READ 中文😀".utf8).base64EncodedString()) == true else { throw WorkbenchError.message("允许读取后OSC52未返回正确文本") }
        probe.response = Data(); probe.clipboard.resetPermission(); probe.interactive = false
        terminal.feed(text: "\u{1b}]52;c;?\u{7}")
        guard probe.response.isEmpty else { throw WorkbenchError.message("后台终端读取了剪贴板") }
        probe.interactive = true; store.terminalClipboardReadAllowed = false
        terminal.feed(text: "\u{1b}]52;c;?\u{7}")
        guard probe.response.isEmpty else { throw WorkbenchError.message("关闭读取设置没有立即生效") }
        store.terminalClipboardReadAllowed = true
        board.clearContents(); board.setData(Data([1, 2, 3]), forType: .png)
        guard probe.clipboard.read(interactive: true) == nil else { throw WorkbenchError.message("终端协议不应读取图片/文件附件") }
        board.clearContents(); board.setString(String(repeating: "x", count: 1024 * 1024 + 1), forType: .string)
        guard probe.clipboard.read(interactive: true) == nil else { throw WorkbenchError.message("读取超过上限") }
        store.terminalClipboardWritePolicy = .allow
        let reopened = try AppStore()
        guard reopened.terminalClipboardWritePolicy == .allow, reopened.terminalClipboardReadAllowed else { throw WorkbenchError.message("剪贴板策略未持久保存") }
        print("PASS · OSC52始终允许/询问/禁止写入、独立文本读取、前后台隔离、策略立即生效/保存/重连及1MiB限制")
        fflush(stdout)
    }
}
