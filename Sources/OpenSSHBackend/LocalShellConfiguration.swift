import Foundation
import Darwin
import WorkbenchCore

public struct LocalShellConfiguration: Sendable {
    public let executable: String
    public let executableName: String
    public let directory: String
    public let environment: [String: String]

    public static var userShell: String {
        guard let account = getpwuid(getuid()), let shell = account.pointee.pw_shell, shell.pointee != 0 else { return "/bin/zsh" }
        return String(cString: shell)
    }

    public init(shell: String = LocalShellConfiguration.userShell,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                currentDirectory: String? = nil) throws {
        var isDirectory: ObjCBool = false
        guard shell.hasPrefix("/"), !shell.contains("\0"),
              FileManager.default.fileExists(atPath: shell, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: shell) else {
            throw WorkbenchError.message(L10n.text("本机登录 Shell 不可执行：\(shell)。请检查系统用户的登录 Shell 设置。"))
        }
        guard home.isFileURL, FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkbenchError.message(L10n.text("本机用户主目录不可用。"))
        }
        executable = shell
        executableName = "-" + (shell as NSString).lastPathComponent
        if let currentDirectory, TerminalDirectory.validPath(currentDirectory),
           FileManager.default.fileExists(atPath: currentDirectory, isDirectory: &isDirectory), isDirectory.boolValue,
           FileManager.default.isExecutableFile(atPath: currentDirectory) { directory = currentDirectory }
        else { directory = home.path }
        var environment = inheritedEnvironment
        for key in environment.keys where key.hasPrefix("SWB_") || ["FARPORT_LANGUAGE", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"].contains(key) {
            environment.removeValue(forKey: key)
        }
        environment["HOME"] = home.path
        environment["PWD"] = directory
        environment["SHELL"] = shell
        environment["USER"] = NSUserName()
        environment["LOGNAME"] = NSUserName()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = TerminalGraphics.program
        for key in TerminalGraphics.environmentKeys { environment.removeValue(forKey: key) }
        if environment["PATH"]?.isEmpty != false { environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        if environment["LANG"]?.isEmpty != false { environment["LANG"] = "en_US.UTF-8" }
        self.environment = environment
    }
}
