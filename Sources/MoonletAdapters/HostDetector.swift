import Foundation
import MoonletCore

/// Identifies the terminal session that launched a hook, without spawning processes.
public enum HostDetector {
    /// Host details for the agent that spawned this process: the bundle identifier and
    /// terminal program from `environment`, plus the agent's pid and controlling tty from
    /// the kernel. Shells between the agent and this process (as in `sh -c`) are skipped.
    public static func detect(environment: [String: String], parentPID: pid_t = getppid()) -> HostInfo {
        var host = HostInfo(environment: environment)
        var pid = parentPID
        guard var details = processDetails(pid) else { return host }
        for _ in 0..<3 {
            guard shells.contains(details.name), details.parent > 1, let parent = processDetails(details.parent) else {
                break
            }
            pid = details.parent
            details = parent
        }
        host.pid = pid
        host.tty = details.tty
        return host
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh"]

    private struct ProcessDetails {
        let name: String
        let parent: pid_t
        let tty: String?
    }

    /// The name, parent, and controlling terminal of a process, via `sysctl(KERN_PROC_PID)`.
    private static func processDetails(_ pid: pid_t) -> ProcessDetails? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }

        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        var tty: String?
        let device = info.kp_eproc.e_tdev
        if device != -1, let deviceName = devname(device, S_IFCHR) {
            let name = String(cString: deviceName)
            if !name.isEmpty, !name.hasPrefix("?"), !name.hasPrefix("#") {
                tty = "/dev/" + name
            }
        }
        return ProcessDetails(name: name, parent: info.kp_eproc.e_ppid, tty: tty)
    }
}
