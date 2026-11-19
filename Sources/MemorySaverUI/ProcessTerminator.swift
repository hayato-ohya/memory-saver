import Darwin
import Foundation
import MemorySaverCore

public enum TerminationResult: Equatable, Sendable {
    /// The process was asked to quit (SIGTERM). It is expected to exit on its own.
    case requested
    /// The process has already exited, or its pid now belongs to another process; nothing was sent.
    case notRunning
    /// Nothing was sent.
    case failed(String)
}

/// What the terminator needs to know about a live process, read fresh just before signalling.
public struct LiveProcessIdentity: Equatable, Sendable {
    public var executablePath: String?
    public var startTime: Date?
    public var isOwnedByCurrentUser: Bool

    public init(executablePath: String?, startTime: Date?, isOwnedByCurrentUser: Bool) {
        self.executablePath = executablePath
        self.startTime = startTime
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
    }
}

/// The system calls behind terminating a helper, so the checks can be tested with a fake.
public protocol ProcessControlling: Sendable {
    /// nil when no process with this pid is running.
    func identity(pid: Int32) -> LiveProcessIdentity?
    /// Sends SIGTERM. Returns the errno on failure, nil on success.
    func sendTerminate(pid: Int32) -> Int32?
}

public struct SystemProcessController: ProcessControlling {
    public init() {}

    public func identity(pid: Int32) -> LiveProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = info.pbi_start_tvsec > 0
            ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            : nil
        return LiveProcessIdentity(
            executablePath: Self.executablePath(pid: pid), startTime: start,
            isOwnedByCurrentUser: info.pbi_uid == getuid())
    }

    public func sendTerminate(pid: Int32) -> Int32? {
        kill(pid, SIGTERM) == 0 ? nil : errno
    }

    private static func executablePath(pid: Int32) -> String? {
        let size = 4 * Int(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: size)
        let length = proc_pidpath(pid, &buffer, UInt32(size))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Asks one helper process of an app to quit. Only SIGTERM is ever sent, never SIGKILL, and
/// never to the app's main process (relaunching is for that) or to system agents.
public struct ProcessTerminator: Sendable {
    private let controller: any ProcessControlling

    public init(controller: any ProcessControlling = SystemProcessController()) {
        self.controller = controller
    }

    public static func canTerminate(_ process: ProcessSample, in app: AppMemoryUsage) -> Bool {
        app.canRelaunch && process.pid != app.mainPID && process.pid != getpid() && process.pid > 1
    }

    public func terminate(_ process: ProcessSample, in app: AppMemoryUsage) -> TerminationResult {
        guard Self.canTerminate(process, in: app) else {
            return .failed(tr(.processTerminateErrorUnsupported))
        }
        // The snapshot can be a minute old and pids get reused: only signal the same process.
        guard let live = controller.identity(pid: process.pid),
              live.executablePath == process.executablePath,
              Self.sameStart(live.startTime, process.startTime)
        else {
            return .notRunning
        }
        guard live.isOwnedByCurrentUser else {
            return .failed(tr(.processTerminateErrorUnsupported))
        }
        if let error = controller.sendTerminate(pid: process.pid) {
            return error == ESRCH ? .notRunning : .failed(String(cString: strerror(error)))
        }
        return .requested
    }

    private static func sameStart(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 0.001
    }
}
