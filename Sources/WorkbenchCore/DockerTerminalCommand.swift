import Foundation

public struct DockerTerminalCommand: Equatable, Sendable {
    public let container: String
    public let user: String?
    public let context: String?
    public let host: String?
    public let attachesExistingProcess: Bool
    public var connectionArguments: [String] {
        if let context { return ["--context", context] }
        if let host { return ["--host", host] }
        return []
    }

    public init(arguments: [String]) throws {
        func unsupported() -> Error { WorkbenchError.message(L10n.text("仅支持本机 tmux 中直接运行的 docker exec -it 或 docker attach；请使用实际容器连接。")) }
        guard arguments.count >= 3, (arguments[0] as NSString).lastPathComponent == "docker" else { throw unsupported() }
        var index = 1
        var context: String?
        var host: String?
        while index < arguments.count, arguments[index].hasPrefix("-") {
            let option = arguments[index]; index += 1
            if ["--context", "-c", "--host", "-H"].contains(option) {
                guard index < arguments.count else { throw unsupported() }
                if option == "--context" || option == "-c" {
                    guard context == nil else { throw unsupported() }; context = arguments[index]
                } else {
                    guard host == nil else { throw unsupported() }; host = arguments[index]
                }
                index += 1
            } else if option.hasPrefix("--context=") || (option.hasPrefix("-c") && !option.hasPrefix("--")) {
                guard context == nil else { throw unsupported() }; context = String(option.dropFirst(option.hasPrefix("--") ? 10 : 2))
            } else if option.hasPrefix("--host=") || (option.hasPrefix("-H") && !option.hasPrefix("--")) {
                guard host == nil else { throw unsupported() }; host = String(option.dropFirst(option.hasPrefix("--") ? 7 : 2))
            } else { throw unsupported() }
        }
        guard context == nil || host == nil, context?.isEmpty != true, host?.isEmpty != true else { throw unsupported() }
        if let host { try DockerUnixEndpoint.validate(host) }
        guard index < arguments.count else { throw unsupported() }
        if arguments[index] == "container" { index += 1 }
        guard index < arguments.count, ["exec", "attach"].contains(arguments[index]) else { throw unsupported() }
        let operation = arguments[index]; index += 1
        var interactive = operation == "attach"
        var terminal = operation == "attach"
        var user: String?
        while index < arguments.count, arguments[index].hasPrefix("-") {
            let option = arguments[index]; index += 1
            if option == "--" { break }
            if option == "--interactive" { interactive = true; continue }
            if option == "--tty" { terminal = true; continue }
            if option.hasPrefix("-") && !option.hasPrefix("--") && option.dropFirst().allSatisfy({ $0 == "i" || $0 == "t" }) {
                interactive = interactive || option.contains("i"); terminal = terminal || option.contains("t"); continue
            }
            guard operation == "exec" else { throw unsupported() }
            if ["--user", "-u", "--workdir", "-w", "--env", "-e", "--env-file"].contains(option) {
                guard index < arguments.count else { throw unsupported() }
                if option == "--user" || option == "-u" { user = arguments[index] }
                index += 1; continue
            }
            if option.hasPrefix("--user=") { user = String(option.dropFirst(7)); continue }
            if ["--workdir=", "--env=", "--env-file="].contains(where: { option.hasPrefix($0) }) { continue }
            if option.hasPrefix("-u"), option.count > 2 { user = String(option.dropFirst(2)); continue }
            if (option.hasPrefix("-w") || option.hasPrefix("-e")), option.count > 2 { continue }
            throw unsupported()
        }
        guard interactive, terminal, index < arguments.count else { throw unsupported() }
        let container = arguments[index]
        guard !container.isEmpty, !container.hasPrefix("-"), container.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              context?.isEmpty != true, user?.isEmpty != true else { throw unsupported() }
        if operation == "exec" {
            guard index + 1 < arguments.count else { throw unsupported() }
            let command = (arguments[index + 1] as NSString).lastPathComponent
            guard !["ssh", "mosh", "docker", "podman", "su", "sudo"].contains(command) else { throw unsupported() }
        }
        self.container = container; self.user = user; self.context = context; self.host = host; attachesExistingProcess = operation == "attach"
    }
}
