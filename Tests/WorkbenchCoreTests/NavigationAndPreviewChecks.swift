import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkNavigationAndPreview() throws {
    var history = DirectoryHistory()
    try expect(history.backDestination == nil, "首次浏览没有返回历史")
    history.visited("/one"); history.visited("/one")
    try expect(history.previous.isEmpty, "刷新不增加历史")
    history.visited("/unrelated"); history.visited("/one/child")
    try expect(history.backDestination == "/unrelated", "返回上一跳不等于父目录")
    history.returned(to: "/unrelated")
    try expect(history.current == "/unrelated" && history.backDestination == "/one", "返回逐步消耗历史")
    history.visited("/different"); history.returned(to: "/unrelated"); history.returned(to: "/one")
    try expect(history.current == "/one" && history.backDestination == nil, "分支导航仍可返回起点")
    for index in 0..<150 { history.visited("/folder/\(index)") }
    try expect(history.previous.count == 100, "目录历史有容量上限")
    let json = "{\"标题😀\": \"123 true \\\"value\\\"\", \"count\": -1.2e+3, \"valid\": true, \"other\": null}"
    let tokens = SyntaxHighlighting.tokens(json, language: .json)
    let text = json as NSString
    try expect(tokens.filter { $0.kind == .key }.count == 4, "JSON key 识别，含中文和 emoji 的 UTF16 范围正确")
    try expect(tokens.filter { $0.kind == .number }.map { text.substring(with: $0.range) } == ["-1.2e+3"], "JSON 字符串内的数字不误高亮")
    try expect(tokens.filter { $0.kind == .literal }.count == 2, "JSON 布尔及 null 高亮")
    let xml = "<?xml version=\"1.0\"?><root name='测试😀'><child>true</child><!-- <ignore/> --><![CDATA[<raw/>]]></root>"
    let xmlTokens = SyntaxHighlighting.tokens(xml, language: .xml)
    try expect(xmlTokens.contains(where: { $0.kind == .comment }) && xmlTokens.filter({ $0.kind == .string }).count == 3, "XML 标签属性、注释、CDATA 分离")
    for (source, syntax) in [(json, SyntaxLanguage.json), (xml, .xml), ("{\"unfinished\\", .json), ("<!--unfinished", .xml)] {
        let spans = SyntaxHighlighting.tokens(source, language: syntax)
        var end = 0
        for span in spans { try expect(span.range.location >= end && NSMaxRange(span.range) <= source.utf16.count, "语法 token 不重叠且不越界"); end = NSMaxRange(span.range) }
    }
    let big = String(repeating: "\"a\":123,", count: 60_000)
    let start = Date(); _ = SyntaxHighlighting.tokens(big, language: .json)
    try expect(Date().timeIntervalSince(start) < 5, "大预览高亮有界耗时")
    try expect(AppLanguage.resolve("system", preferred: ["zh-Hant-US"]) == .simplifiedChinese && AppLanguage.resolve("system", preferred: ["fr"]) == .english, "系统语言与不支持语言回退")
    try expect(AppLanguage.resolve("en", preferred: ["zh-Hans"]) == .english, "显式选择覆盖系统语言")
    try expect(L10n.translations.count > 600, "英文语言资源完整加载")
    for (key, value) in L10n.translations {
        let regex = try NSRegularExpression(pattern: "\\{[0-9]+\\}")
        func placeholders(_ text: String) -> [String] { regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map { (text as NSString).substring(with: $0.range) }.sorted() }
        try expect(placeholders(key) == placeholders(value), "翻译保留插值占位符：\(key)")
    }
    let filename = "私人文件{1}.json"
    try expect(L10n.render("源：\(filename)", language: .english) == "Source: 私人文件{1}.json", "翻译不改写文件名，不二次展开插值")
    try expect(L10n.render("源：\(filename)", language: .simplifiedChinese) == "源：私人文件{1}.json", "中文保持原有文案")
}

func checkEnglishRuntime() throws {
    try expect(L10n.language == .english, "运行语言为英文")
    try expect(L10n.text("返回上次访问的目录") == "Back to the previous folder", "文件导航英文文案")
    try expect(FileSortColumn.name.title == "Name" && HostMarkColor.blue.title == "Blue", "核心标签英文")
    try expect(TransferStatus.awaitingConfirmation.title == "Awaiting confirmation", "传输状态英文")
    try expect(WorkbenchError.message(L10n.text("文件已发生变化，请重新读取。")).localizedDescription.contains("file changed"), "错误消息英文")
    print("PASS · 英文运行时、核心标签和错误提示，资源 \(L10n.translations.count) 条")
}
