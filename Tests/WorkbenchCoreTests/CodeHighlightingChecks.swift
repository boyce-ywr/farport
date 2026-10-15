import Foundation
import WorkbenchCore

func checkCodeHighlighting() throws {
    let extensions: [(String, SyntaxLanguage)] = [("Example.JAVA", .java), ("hello.py", .python), ("app.jsx", .javascript), ("view.tsx", .typescript), ("run.sh", .shell), ("main.go", .go), ("lib.rs", .rust), ("main.c", .c), ("header.hpp", .cpp), ("App.swift", .swift), ("query.sql", .sql), ("config.yaml", .yaml), ("config.toml", .toml)]
    for (file, expected) in extensions { try expect(SyntaxHighlighting.language(for: file) == expected, "常见源码扩展名：\(file)") }
    func values(_ source: String, _ language: SyntaxLanguage, _ kind: SyntaxTokenKind) -> [String] {
        SyntaxHighlighting.tokens(source, language: language).filter { $0.kind == kind }.map { (source as NSString).substring(with: $0.range) }
    }
    let java = "public class Demo { // return false 123\n String text = \"class true 42 中文😀\"; int n = 1+2; return; }"
    try expect(values(java, .java, .keyword) == ["public", "class", "int", "return"], "Java 注释和字符串内不匹配关键字")
    try expect(values(java, .java, .number) == ["1", "2"], "数字高亮不吞掉加法操作符")
    let python = "@cache\ndef greet(name):\n    '''class false 99\n多行文档😀'''\n    # return 777\n    return f\"Hello {name}\", True, 1e-3\n"
    try expect(values(python, .python, .keyword) == ["def", "return"], "Python 三引号和注释正确跳过")
    try expect(values(python, .python, .literal) == ["True"] && values(python, .python, .number) == ["1e-3"], "Python 布尔及指数数值")
    try expect(values("const value = `// test\ntrue`; function load() { return false; }", .javascript, .keyword) == ["const", "function", "return"], "JS 模板字符串不染成注释")
    try expect(values("let value: &str = \"text\"; fn get<'a>(s: &'a str) {}", .rust, .keyword).contains("fn"), "Rust 生命周期不吞掉后续源码")
    try expect(values("SELECT 'it''s true' FROM data WHERE enabled = true -- SELECT", .sql, .keyword) == ["SELECT", "FROM", "WHERE"], "SQL 不区分关键字大小写，支持引号转义")
    try expect(values("package main\nvar text = `\\raw // not a comment`\nfunc main() {}", .go, .keyword) == ["package", "var", "func"], "Go 反引号原始字符串")
    try expect(values("if test -n \"$HOME\"; then echo ${USER}; fi # exit", .shell, .variable) == ["${USER}"], "Shell 变量与注释")
    try expect(values("/* outer /* inner */ end */ let x = 3", .swift, .keyword) == ["let"], "Swift 嵌套块注释")
    try expect(values("name: test\nenabled: true # comment", .yaml, .key) == ["name", "enabled"], "YAML 键高亮")
    try expect(values("[server]\nport = 8080\nname = 'demo'", .toml, .key) == ["port", "name"], "TOML 键高亮")
    for language in SyntaxLanguage.allCases {
        for source in [java, python, "\"unfinished\\", "/*", "'''", "😀 注释", String(repeating: "let count = 123; // note\n", count: 3000)] {
            var end = 0
            for token in SyntaxHighlighting.tokens(source, language: language) {
                guard token.range.location >= end, token.range.length > 0, NSMaxRange(token.range) <= source.utf16.count else { throw WorkbenchError.message("源码 token 越界或重叠") }
                end = NSMaxRange(token.range)
            }
        }
        try expect(true, "\(language) 残缺/Unicode/大文本边界")
    }
}
