import Foundation

/// 终端里被 Cmd+点击的路径文本（SwiftTerm 隐式识别结果或 OSC 8 `file://` 链接），解析成目标主机上待检查的候选路径。
/// 只做纯文本处理；路径是否存在、是目录还是文件，由调用方在目标主机上 `stat` 决定。
public struct TerminalPathLink: Equatable, Sendable {
    /// 去掉行列号后的路径文本；第二项（若有）是去掉紧贴的中文前缀后的版本。
    public let variants: [String]

    public static func isWebLink(_ link: String) -> Bool {
        guard let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public init?(link: String, trustedHosts: Set<String>) {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4096, text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if text.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) != nil || text.range(of: #"^(?i:mailto|tel|magnet|news|ssh|file):"#, options: .regularExpression) != nil {
            // `file://` 主机为空或 localhost 时指程序所在的机器，即目标主机自身。
            guard let path = TerminalDirectory.path(from: text, allowedHosts: trustedHosts.union(["", "localhost"])) else { return nil }
            text = path
        }
        text = Self.trimmingTrailingPunctuation(text)
        if let location = text.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) { text = String(text[..<location.lowerBound]) }
        guard !text.isEmpty else { return nil }
        var variants = [text]
        // SwiftTerm 的正则把汉字算作单词字符，“已记入docs/a.md”会整体命中；去掉开头紧贴的 CJK 字符与全角标点再试。
        let stripped = String(String.UnicodeScalarView(text.unicodeScalars.drop(while: Self.isLeadingNoise)))
        if !stripped.isEmpty, stripped != text { variants.append(stripped) }
        self.variants = variants
    }

    /// 按优先级列出候选绝对路径：绝对路径与 `~` 只有一个结果；相对路径依次拼接各基准目录。
    public func candidates(home: String?, bases: [String]) -> [String] {
        var result: [String] = []
        func add(_ path: String) { if TerminalDirectory.validPath(path), !result.contains(path) { result.append(path) } }
        for variant in variants {
            if variant == "~" || variant == "$HOME" { if let home { add(home) } }
            else if variant.hasPrefix("~/") { if let home { add(RemotePath.join(home, String(variant.dropFirst(2)))) } }
            else if variant.hasPrefix("$HOME/") { if let home { add(RemotePath.join(home, String(variant.dropFirst(6)))) } }
            else if variant.hasPrefix("/") { add(variant) }
            else if variant.hasPrefix("~") || variant.hasPrefix("$") { continue }
            else { for base in bases where base.hasPrefix("/") { add(RemotePath.join(base, variant)) } }
        }
        return result
    }

    private static func trimmingTrailingPunctuation(_ text: String) -> String {
        let trailing = CharacterSet(charactersIn: "。，、；：！？）」』】》”’")
        var scalars = text.unicodeScalars
        while let last = scalars.last, trailing.contains(last) { scalars.removeLast() }
        return String(scalars)
    }

    /// CJK 统一表意文字、假名、谚文及全角标点都位于 U+2E80 之后；路径里的 ASCII 部分不受影响。
    private static func isLeadingNoise(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x2E80 }
}
