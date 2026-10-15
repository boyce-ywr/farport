import Foundation

enum CodeHighlighting {
    private static let keywords: [SyntaxLanguage: Set<String>] = {
        let lists: [SyntaxLanguage: String] = [
            .java: "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for if implements import instanceof int interface long native new package private protected public record return sealed short static strictfp super switch synchronized this throw throws transient try var void volatile while yield permits non-sealed",
            .python: "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case type",
            .javascript: "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield",
            .typescript: "abstract any as async await boolean break case catch class const constructor continue declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new number object of private protected public readonly require return set static string super switch symbol this throw try type typeof undefined unknown var void while with yield satisfies",
            .shell: "if then else elif fi for while until do done case esac in function select time coproc local export readonly declare typeset unset return break continue source alias unalias trap eval exec set shift test echo printf cd pwd read exit",
            .go: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var string int int64 uint byte rune bool float64 error make len append cap new",
            .rust: "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while yield bool char str i8 i16 i32 i64 u8 u16 u32 u64 usize isize f32 f64",
            .c: "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Bool _Atomic",
            .cpp: "alignas alignof auto bool break case catch char class concept const constexpr consteval constinit continue decltype default delete do double else enum explicit export extern final float for friend goto if inline int long mutable namespace new noexcept nullptr operator override private protected public register requires return short signed sizeof static static_assert struct switch template this thread_local throw try typedef typename union unsigned using virtual void volatile wchar_t while co_await co_return co_yield",
            .swift: "actor any as associatedtype async await break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect init inout internal is isolated lazy let mutating nonisolated nonmutating open operator override private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet",
            .sql: "select from where insert into values update set delete create alter drop table view index join inner outer left right full on as and or not null is in exists between like order by group having limit offset distinct union all case when then else end primary key foreign references constraint unique default with recursive begin commit rollback asc desc count sum avg min max",
            .yaml: "", .toml: ""
        ]
        return lists.mapValues { Set($0.split(separator: " ").map(String.init)) }
    }()

    static func tokens(_ source: String, language: SyntaxLanguage) -> [SyntaxToken] {
        let units = Array(source.utf16)
        let words = keywords[language] ?? []
        let literals: Set<String> = ["true", "false", "null", "nil", "none", "undefined", "nullptr"]
        let hashComments = [.python, .shell, .yaml, .toml].contains(language)
        let slashComments = !hashComments && language != .sql
        let backticks = [.javascript, .typescript, .go, .shell].contains(language)
        var cursor = 0; var result: [SyntaxToken] = []
        func matches(_ pattern: [UInt16], _ index: Int) -> Bool {
            index + pattern.count <= units.count && units[index..<(index + pattern.count)].elementsEqual(pattern)
        }
        func identifierStart(_ unit: UInt16) -> Bool {
            unit == 95 || (65...90).contains(unit) || (97...122).contains(unit) || unit >= 128
        }
        func identifierPart(_ unit: UInt16) -> Bool { identifierStart(unit) || (48...57).contains(unit) }
        func add(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) {
            if end > start { result.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind)) }
        }
        while cursor < units.count {
            let start = cursor; let unit = units[cursor]
            if (hashComments && unit == 35 && (language != .shell || cursor == 0 || [9, 10, 13, 32, 59].contains(units[cursor - 1]))) || (slashComments && matches([47, 47], cursor)) || (language == .sql && matches([45, 45], cursor)) {
                while cursor < units.count && units[cursor] != 10 { cursor += 1 }; add(start, cursor, .comment)
            } else if !hashComments && matches([47, 42], cursor) {
                cursor += 2; var depth = 1
                while cursor < units.count && depth > 0 {
                    if [.rust, .swift].contains(language) && matches([47, 42], cursor) { depth += 1; cursor += 2 }
                    else if matches([42, 47], cursor) { depth -= 1; cursor += 2 }
                    else { cursor += 1 }
                }
                add(start, cursor, .comment)
            } else if unit == 34 || unit == 39 || (unit == 96 && backticks) {
                if language == .rust && unit == 39 && cursor + 1 < units.count && identifierStart(units[cursor + 1]) {
                    var end = cursor + 2
                    while end < units.count && identifierPart(units[end]) { end += 1 }
                    if end >= units.count || units[end] != 39 { cursor = end; add(start, cursor, .variable); continue }
                }
                let triple = [.python, .java, .swift, .toml].contains(language) && matches([unit, unit, unit], cursor)
                let terminator: [UInt16] = triple ? [unit, unit, unit] : [unit]
                let raw = (language == .go && unit == 96) || ([.shell, .toml].contains(language) && unit == 39)
                cursor += terminator.count
                while cursor < units.count {
                    if matches(terminator, cursor) {
                        cursor += terminator.count
                        if !triple && (language == .sql || language == .yaml) && cursor < units.count && units[cursor] == unit { cursor += 1; continue }
                        break
                    }
                    if units[cursor] == 92 && !raw { cursor = min(units.count, cursor + 2) }
                    else { cursor += 1 }
                }
                add(start, cursor, .string)
            } else if language == .shell && unit == 36 {
                cursor += 1
                if cursor < units.count && units[cursor] == 123 {
                    cursor += 1
                    while cursor < units.count && units[cursor] != 125 { cursor += 1 }
                    if cursor < units.count { cursor += 1 }
                } else { while cursor < units.count && (identifierPart(units[cursor]) || [63, 35, 64, 42, 36].contains(units[cursor])) { cursor += 1 } }
                add(start, cursor, .variable)
            } else if (48...57).contains(unit) {
                cursor += 1
                while cursor < units.count {
                    let next = units[cursor]
                    if identifierPart(next) || next == 46 { cursor += 1 }
                    else if [43, 45].contains(next) && [69, 101, 80, 112].contains(units[cursor - 1]) { cursor += 1 }
                    else { break }
                }
                add(start, cursor, .number)
            } else if identifierStart(unit) {
                cursor += 1
                while cursor < units.count && identifierPart(units[cursor]) { cursor += 1 }
                let word = String(decoding: units[start..<cursor], as: UTF16.self)
                let lookup = language == .sql ? word.lowercased() : word
                var next = cursor
                while next < units.count && [9, 32].contains(units[next]) { next += 1 }
                if words.contains(lookup) { add(start, cursor, .keyword) }
                else if literals.contains(word.lowercased()) { add(start, cursor, .literal) }
                else if [.yaml, .toml].contains(language) && next < units.count && [58, 61].contains(units[next]) { add(start, cursor, .key) }
                else if next < units.count && units[next] == 40 { add(start, cursor, .function) }
            } else { cursor += 1 }
        }
        return result
    }
}
