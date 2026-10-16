import Foundation
import CoreFoundation
import WorkbenchCore

public enum CommandDiagnostic {
    public static func decode(_ data: Data) -> String {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: encoding) { return text }
        return L10n.text("远端错误信息使用了无法识别的编码，请在目标主机检查 SSH 日志。")
    }
}
