import WorkbenchCore
import AppKit
import Security
import CryptoKit

if CommandLine.arguments.contains("--check-localization") {
    guard !L10n.translations.isEmpty else { exit(1) }
    print(L10n.text("取消")); exit(0)
}

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let environment = ProcessInfo.processInfo.environment
let silent = environment["SWB_SILENT_AUTH"] == "1"
if silent, SecKeychainSetUserInteractionAllowed(false) != errSecSuccess { exit(1) }
let host = environment["SWB_HOST_LABEL"] ?? L10n.text("SSH 主机")
let identifier = environment["SWB_CREDENTIAL_ACCOUNT"] ?? "unknown"
let digest = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
let account = identifier + ":" + digest
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: "local.sshworkbench.credentials",
                           kSecAttrAccount as String: account]
let lower = prompt.lowercased()
let isTrust = lower.contains("yes/no") || lower.contains("are you sure")
let isPassword = !isTrust && (lower.contains("password:") || lower.contains("passphrase"))
if isPassword {
    var lookup = query; lookup[kSecReturnData as String] = true
    if silent { lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
    var item: CFTypeRef?
    if SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
       let data = item as? Data, let value = String(data: data, encoding: .utf8) {
        print(value); exit(0)
    }
}
if silent { exit(1) }
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let alert = NSAlert(); alert.messageText = isTrust ? L10n.text("验证 \(host) 的主机指纹") : L10n.text("连接 \(host)")
alert.informativeText = prompt
alert.alertStyle = isTrust ? .warning : .informational
alert.addButton(withTitle: isTrust ? L10n.text("信任并连接") : L10n.text("继续"))
alert.addButton(withTitle: L10n.text("取消"))
let field = NSSecureTextField(frame: NSRect(x: 0, y: 34, width: 400, height: 26))
let remember = NSButton(checkboxWithTitle: L10n.text("保存到 macOS 钥匙串（不适用于一次性验证码）"), target: nil, action: nil)
remember.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
if !isTrust {
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 66)); accessory.addSubview(field)
    if isPassword { accessory.addSubview(remember) }
    alert.accessoryView = accessory; alert.window.initialFirstResponder = field
}
application.activate(ignoringOtherApps: true)
guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
let value = isTrust ? "yes" : field.stringValue
if isPassword && remember.state == .on {
    var stored = query; stored[kSecValueData as String] = Data(value.utf8)
    stored[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    SecItemDelete(query as CFDictionary)
    let status = SecItemAdd(stored as CFDictionary, nil)
    if status != errSecSuccess { fputs(L10n.text("未能将凭据保存到钥匙串。\n"), stderr) }
}
print(value)
