import Foundation
import WorkbenchCore
import OpenSSHBackend

func checkTerminalGraphics() throws {
    let config = try LocalShellConfiguration(inheritedEnvironment: ["TERM_PROGRAM": "other", "KITTY_WINDOW_ID": "old", "TMUX": "/tmp/tmux"])
    try expect(config.environment["TERM_PROGRAM"] == TerminalGraphics.program, "Farport 声明自身和 Kitty 图像兼容能力")
    try expect(config.environment["TERM"] == "xterm-256color", "图像支持不要求远端新 terminfo")
    try expect(config.environment["KITTY_WINDOW_ID"] == nil, "不继承其他终端的窗口标识")
    let inline = "\u{1b}_Ga=T,t=d,f=24,s=1,v=1,i=42;/wAA\u{1b}\\"
    var input = TerminalGraphicsInput()
    let bytes = Array(inline.utf8)
    var filtered = [UInt8]()
    for byte in bytes { filtered += input.filter([byte][...]) }
    try expect(filtered == bytes, "Kitty 内嵌图像逐字节分包重组")
    for transport in ["f", "t", "s"] {
        let external = "\u{1b}_Ga=q,t=\(transport),f=100,i=43;L3RtcC9zZWNyZXQ=\u{1b}\\"
        try expect(input.filter(Array(external.utf8)[...]).isEmpty, "图像协议不得读取/删除宿主文件或共享内存")
    }
    let first = "\u{1b}_Ga=T,t=d,f=24,s=1,v=1,m=1;/w\u{1b}\\"
    let last = "\u{1b}_Gm=0;AA\u{1b}\\"
    try expect(input.filter(Array(first.utf8)[...]).isEmpty, "未完成图像不送入无限累积缓存")
    try expect(input.filter(Array(last.utf8)[...]) == Array((first + last).utf8), "多段图像验证完成后转发")
    let tooLarge = "\u{1b}_Ga=T,f=32,s=100000,v=100000;AAAAAA==\u{1b}\\"
    try expect(input.filter(Array(tooLarge.utf8)[...]).isEmpty, "过大图像尺寸拒绝")
    let text = "中文 \u{1b}[31mtext\u{1b}[0m"
    try expect(input.filter(Array(text.utf8)[...]) == Array(text.utf8), "普通UTF8与ANSI原样转发")
    let deletion = "\u{1b}_Ga=d,d=I,i=42,q=2;\u{1b}\\"
    try expect(input.filter(Array(deletion.utf8)[...]) == Array(deletion.utf8), "图像删除指令保留")
    let c1 = [UInt8]([0x9f]) + Array("Ga=T,t=f,f=100,i=43;L3RtcC9zZWNyZXQ=".utf8) + [0x9c]
    try expect(input.filter(c1[...]).isEmpty, "8位APC不能绕过宿主文件访问限制")
    let unicode = Array("中文 😀 🐟".utf8)
    var unicodeResult = [UInt8]()
    for byte in unicode { unicodeResult += input.filter([byte][...]) }
    try expect(unicodeResult == unicode, "UTF8续字节不误当作8位APC")
    let oversizedPlacement = "\u{1b}_Ga=p,i=42,c=2147483647;\u{1b}\\"
    try expect(input.filter(Array(oversizedPlacement.utf8)[...]).isEmpty, "拒绝超大图像显示区域")
    let invalidDuplicate = "\u{1b}_Ga=T,t=d,t=f,f=24,s=1,v=1;/wAA\u{1b}\\"
    try expect(input.filter(Array(invalidDuplicate.utf8)[...]).isEmpty, "重复参数不能绕过传输限制")
    let limit = Array("\u{1b}_Ga=T,f=100,m=1;".utf8) + [UInt8](repeating: 65, count: 16 * 1024 * 1024 + 1) + [27, 92]
    try expect(input.filter(limit[...]).isEmpty, "超长未完成图像有界丢弃")
    try expect(input.filter(Array(inline.utf8)[...]) == Array(inline.utf8), "超长输入后后续图像可恢复")
    let command = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", TerminalGraphics.loginCommand], environment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "TMUX": "existing", "KITTY_WINDOW_ID": "inherited"], input: Data("printf '%s|%s|%s' \"$TERM_PROGRAM\" \"$TMUX\" \"${KITTY_WINDOW_ID-unset}\"\n".utf8))
    try expect(command.status == 0 && command.text == TerminalGraphics.program + "|existing|unset", "SSH登录脚本保留真实TMUX状态并清理继承标识")
}
