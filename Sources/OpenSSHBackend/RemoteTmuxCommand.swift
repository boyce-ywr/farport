import Foundation
import WorkbenchCore

public enum RemoteTmuxCommand {
    public static let executableReference = "\"$farport_tmux_executable\""
    public static func wrap(_ command: String) -> String {
        let discovery = """
        farport_tmux_executable=$(command -v tmux 2>/dev/null || :)
        case "$farport_tmux_executable" in /*) ;; *) farport_tmux_executable= ;; esac
        if [ ! -f "$farport_tmux_executable" ] || [ ! -x "$farport_tmux_executable" ]; then
            farport_tmux_executable=
            for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux /usr/bin/tmux /bin/tmux; do
                if [ -f "$candidate" ] && [ -x "$candidate" ]; then farport_tmux_executable=$candidate; break; fi
            done
        fi
        if [ -z "$farport_tmux_executable" ]; then
            printf '%s\\n' 'Farport: 未找到可执行的 tmux；已检查远端 PATH 和 Homebrew 常用路径。请确认安装位置。' >&2
            exit 127
        fi
        """
        return "/bin/sh -c " + RemotePath.quote(discovery + "\n" + command)
    }
    public static func attach(session: String) -> String {
        wrap("exec " + executableReference + " attach-session -t " + RemotePath.quote(session))
    }
}
