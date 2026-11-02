import AppKit
import os

/// Only one Switch may run: a second one would add a second menu bar icon, and its
/// resolver would resize VS Code's minimized windows alongside the first one's.
/// LaunchServices keeps a plain launch from starting a second process, but not
/// `open -n` or a copy of the app elsewhere, so the app checks for itself.
enum SingleInstance {
    struct Instance: Equatable {
        let processIdentifier: pid_t
        let started: Date
    }

    /// The oldest stays. Comparing, rather than leaving whenever another exists, keeps
    /// two instances starting together from both leaving.
    static func shouldLeave(own: Instance, others: [Instance]) -> Bool {
        others.contains { ($0.started, $0.processIdentifier) < (own.started, own.processIdentifier) }
    }

    /// From the kernel, because `NSRunningApplication.launchDate` is nil for a process
    /// LaunchServices did not start. Nil when the process has already gone.
    private static func instance(_ processIdentifier: pid_t) -> Instance? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Instance(processIdentifier: processIdentifier,
                        started: Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000))
    }

    static func anotherInstanceIsRunning() -> Bool {
        let current = NSRunningApplication.current
        guard let identifier = Bundle.main.bundleIdentifier else {
            fatalError("Switch has no bundle identifier")
        }
        guard let own = instance(current.processIdentifier) else {
            fatalError("Cannot read this process's start time")
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current.processIdentifier }
            .compactMap { instance($0.processIdentifier) }
        let leave = shouldLeave(own: own, others: others)
        if leave {
            Logger(subsystem: "com.tranworks.switch", category: "launch").notice("another Switch is running, leaving")
        }
        return leave
    }
}
