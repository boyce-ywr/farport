import Foundation
import WorkbenchCore

func checkTerminalPathLinks() throws {
    let trusted: Set<String> = ["sh-linux"]
    func candidates(_ link: String, home: String? = "/home/ywr", bases: [String] = ["/home/ywr/projects/kaihua"]) -> [String]? {
        TerminalPathLink(link: link, trustedHosts: trusted)?.candidates(home: home, bases: bases)
    }
    try expect(TerminalPathLink.isWebLink("https://example.com/a") && !TerminalPathLink.isWebLink("docs/a.md"), "仅 http(s) 走浏览器")
    try expect(candidates("~/projects/personal/kaihua/") == ["/home/ywr/projects/personal/kaihua/"], "波浪号按目标主机 HOME 展开")
    try expect(candidates("~/a", home: nil) == [], "未知 HOME 时不猜测波浪号")
    try expect(candidates("$HOME/a") == ["/home/ywr/a"], "展开 $HOME")
    try expect(candidates("$PROJECT/a") == [], "其他环境变量不展开")
    try expect(candidates("/etc/hosts") == ["/etc/hosts"], "绝对路径原样")
    try expect(candidates("docs/decisions.md", bases: ["/w/a", "/home/ywr"]) == ["/w/a/docs/decisions.md", "/home/ywr/docs/decisions.md"], "相对路径按基准目录顺序")
    try expect(candidates("./a.md", bases: ["/w"]) == ["/w/./a.md"], "./ 相对路径")
    try expect(candidates("Sources/App.swift:12:4") == ["/home/ywr/projects/kaihua/Sources/App.swift"], "剥离行列号")
    try expect(candidates("Sources/App.swift:12") == ["/home/ywr/projects/kaihua/Sources/App.swift"], "剥离行号")
    try expect(candidates("docs/decisions.md。") == ["/home/ywr/projects/kaihua/docs/decisions.md"], "剥离结尾全角标点")
    try expect(candidates("已记入docs/decisions.md", bases: ["/w"]) == ["/w/已记入docs/decisions.md", "/w/docs/decisions.md"], "先原文后去中文前缀")
    try expect(candidates("「~/a」") == ["/home/ywr/projects/kaihua/「~/a", "/home/ywr/a"], "去掉全角引号包裹")
    try expect(candidates("文档/说明.md", bases: ["/w"]) == ["/w/文档/说明.md", "/说明.md"], "中文目录名优先按原文尝试")
    try expect(candidates("file:///home/ywr/a%20b.md") == ["/home/ywr/a b.md"], "OSC 8 file 链接空主机")
    try expect(candidates("file://localhost/tmp/x") == ["/tmp/x"], "OSC 8 file 链接 localhost")
    try expect(candidates("file://sh-linux/tmp/x") == ["/tmp/x"], "OSC 8 file 链接主机名匹配")
    try expect(TerminalPathLink(link: "file://other-host/tmp/x", trustedHosts: trusted) == nil, "拒绝其他主机的 file 链接")
    try expect(TerminalPathLink(link: "mailto:a@b.c", trustedHosts: trusted) == nil, "其他协议不当作路径")
    try expect(TerminalPathLink(link: "ssh://host/a", trustedHosts: trusted) == nil, "ssh 链接不当作路径")
    try expect(TerminalPathLink(link: "a\u{1b}b", trustedHosts: trusted) == nil, "拒绝控制字符")
    try expect(candidates("~other/a") == [], "不展开其他用户的 HOME")
}
