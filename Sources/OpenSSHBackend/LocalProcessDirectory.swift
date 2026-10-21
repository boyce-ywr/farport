import Foundation
import Darwin
import WorkbenchCore

public enum LocalProcessDirectory {
    public static func current(shellPID: Int32) -> String? {
        var shell = proc_bsdinfo()
        guard shellPID > 0, proc_pidinfo(shellPID, PROC_PIDTBSDINFO, 0, &shell, Int32(MemoryLayout.size(ofValue: shell))) == MemoryLayout.size(ofValue: shell),
              shell.pbi_uid == getuid() else { return nil }
        let foreground = Int32(bitPattern: shell.e_tpgid)
        let identifier = foreground > 0 ? foreground : shellPID
        var info = proc_bsdinfo()
        guard proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info), info.pbi_uid == getuid() else { return nil }
        var executable = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(identifier, &executable, UInt32(executable.count)) > 0,
              !["ssh", "mosh", "docker", "podman", "su", "sudo", "tmux"].contains((String(cString: executable) as NSString).lastPathComponent) else { return nil }
        var paths = proc_vnodepathinfo()
        guard proc_pidinfo(identifier, PROC_PIDVNODEPATHINFO, 0, &paths, Int32(MemoryLayout.size(ofValue: paths))) == MemoryLayout.size(ofValue: paths) else { return nil }
        let directory = withUnsafePointer(to: &paths.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        var finalInfo = proc_bsdinfo()
        guard proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, &finalInfo, Int32(MemoryLayout.size(ofValue: finalInfo))) == MemoryLayout.size(ofValue: finalInfo),
              finalInfo.pbi_start_tvsec == info.pbi_start_tvsec, finalInfo.pbi_start_tvusec == info.pbi_start_tvusec,
              TerminalDirectory.validPath(directory) else { return nil }
        return directory
    }
}
