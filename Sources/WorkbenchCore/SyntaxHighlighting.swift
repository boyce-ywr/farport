import Foundation

public enum SyntaxLanguage: CaseIterable, Sendable {
    case json, xml, java, python, javascript, typescript, shell, go, rust, c, cpp, swift, sql, yaml, toml
}
public enum SyntaxTokenKind: Sendable { case key, string, number, literal, tag, comment, keyword, function, variable }
public struct SyntaxToken: Sendable {
    public let range: NSRange
    public let kind: SyntaxTokenKind
}

public enum SyntaxHighlighting {
    public static func language(for path: String) -> SyntaxLanguage? {
        switch (path as NSString).pathExtension.lowercased() {
        case "json", "jsonc": return .json
        case "xml", "svg", "plist", "xhtml": return .xml
        case "java": return .java
        case "py", "pyw", "pyi": return .python
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "sh", "bash", "zsh", "fish": return .shell
        case "go": return .go
        case "rs": return .rust
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hxx": return .cpp
        case "swift": return .swift
        case "sql": return .sql
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        default: return nil
        }
    }
    public static func tokens(_ source: String, language: SyntaxLanguage) -> [SyntaxToken] {
        if language != .json && language != .xml { return CodeHighlighting.tokens(source, language: language) }
        let units = Array(source.utf16)
        var position = 0; var result: [SyntaxToken] = []
        func matches(_ text: String, at index: Int) -> Bool {
            let pattern = Array(text.utf16)
            return index + pattern.count <= units.count && units[index..<(index + pattern.count)].elementsEqual(pattern)
        }
        func endOf(_ terminator: String, from index: Int) -> Int {
            var cursor = index
            while cursor < units.count { if matches(terminator, at: cursor) { return cursor + terminator.utf16.count }; cursor += 1 }
            return units.count
        }
        func append(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) {
            if end > start { result.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind)) }
        }
        while position < units.count {
            let start = position; let unit = units[position]
            if language == .xml, matches("<!--", at: position) {
                position = endOf("-->", from: position + 4); append(start, position, .comment)
            } else if language == .xml, matches("<![CDATA[", at: position) {
                position = endOf("]]>", from: position + 9); append(start, position, .string)
            } else if language == .xml, unit == 60 {
                var segment = position; position += 1
                while position < units.count && units[position] != 62 {
                    if units[position] == 34 || units[position] == 39 {
                        append(segment, position, .tag)
                        let quote = units[position]; let quoted = position; position += 1
                        while position < units.count && units[position] != quote { position += 1 }
                        if position < units.count { position += 1 }
                        append(quoted, position, .string); segment = position
                    } else { position += 1 }
                }
                if position < units.count { position += 1 }; append(segment, position, .tag)
            } else if language == .json, matches("//", at: position) {
                while position < units.count && units[position] != 10 { position += 1 }; append(start, position, .comment)
            } else if language == .json, matches("/*", at: position) {
                position = endOf("*/", from: position + 2); append(start, position, .comment)
            } else if language == .json, unit == 34 {
                position += 1
                while position < units.count {
                    if units[position] == 92 { position = min(units.count, position + 2) }
                    else if units[position] == 34 { position += 1; break }
                    else { position += 1 }
                }
                var next = position
                while next < units.count && [9, 10, 13, 32].contains(units[next]) { next += 1 }
                append(start, position, next < units.count && units[next] == 58 ? .key : .string)
            } else if language == .json, (48...57).contains(unit) || unit == 45 {
                position += 1
                while position < units.count && ((48...57).contains(units[position]) || [43, 45, 46, 69, 101].contains(units[position])) { position += 1 }
                append(start, position, .number)
            } else if language == .json, let literal = ["true", "false", "null"].first(where: { matches($0, at: position) }) {
                position += literal.utf16.count; append(start, position, .literal)
            } else { position += 1 }
        }
        return result
    }
}
