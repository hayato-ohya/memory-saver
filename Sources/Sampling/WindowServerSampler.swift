import Darwin
import Foundation
import MemorySaverCore
import os

/// Reads WindowServer's footprint through `/usr/bin/top`, which is setuid root and so can
/// see a process owned by `_windowserver` where `proc_pid_rusage` cannot.
public struct WindowServerSampler: WindowServerSampling {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout
    }

    public func sample() async -> UInt64? {
        guard let pid = await windowServerPID() else { return nil }
        let arguments = ["-l", "1", "-pid", String(pid), "-stats", "pid,command,mem"]
        guard let output = await runProcess("/usr/bin/top", arguments: arguments, timeout: timeout) else {
            return nil
        }
        return parseTopMemory(output, pid: pid)
    }

    /// When the current WindowServer started. WindowServer is recreated at every login, so
    /// this, not the Mac's boot time, is when its memory was last back to its starting size.
    public func startTime() async -> Date? {
        guard let pid = await windowServerPID() else { return nil }
        return processStartTime(pid: pid)
    }

    func windowServerPID() async -> Int32? {
        if let found = findWindowServerPID() { return found }
        let output = await runProcess("/usr/bin/pgrep", arguments: ["-x", "WindowServer"], timeout: timeout)
        return output?.split(whereSeparator: \.isNewline).first.flatMap { Int32($0) }
    }
}

/// WindowServer's pid, found by executable path. proc_name fails with EPERM for other users'
/// processes, but proc_pidpath does not.
func findWindowServerPID() -> Int32? {
    allPIDs().first { pid in
        guard pid > 0, let path = ProcessSampler.executablePath(pid: pid) else { return false }
        return path.hasSuffix("/WindowServer")
    }
}

/// Start time of any process, including other users' (`proc_pidinfo` refuses those; the
/// `kern.proc.pid` sysctl does not).
func processStartTime(pid: Int32) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let start = info.kp_proc.p_starttime
    guard start.tv_sec > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
}

/// Finds the row for `pid` in `top -stats pid,command,mem` output and returns its MEM value in bytes.
public func parseTopMemory(_ output: String, pid: Int32) -> UInt64? {
    let target = String(pid)
    for line in output.split(whereSeparator: \.isNewline) {
        let fields = line.split(whereSeparator: \.isWhitespace)
        // MEM is the last column; COMMAND may itself contain spaces.
        guard fields.count >= 3, fields[0] == target, let mem = fields.last else { continue }
        return parseTopMemoryValue(String(mem))
    }
    return nil
}

/// Parses a `top` memory value such as `1402M`, `1.5G`, `512K+` or `100B-` into bytes.
public func parseTopMemoryValue(_ text: String) -> UInt64? {
    var value = Substring(text.trimmingCharacters(in: .whitespaces))
    if let last = value.last, last == "+" || last == "-" { value = value.dropLast() }
    guard let unit = value.last else { return nil }

    let multiplier: Double
    switch unit.uppercased() {
    case "B": multiplier = 1
    case "K": multiplier = 0x1p10
    case "M": multiplier = 0x1p20
    case "G": multiplier = 0x1p30
    case "T": multiplier = 0x1p40
    default: return nil
    }
    let digits = value.dropLast()
    // Double() accepts things like "inf" and "1e3"; top only prints plain decimals.
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
          let number = Double(digits), number.isFinite
    else { return nil }
    return UInt64((number * multiplier).rounded())
}

/// Runs a command and returns its stdout, or nil on launch failure, non-zero exit or timeout.
/// Waits with a termination handler, so no thread is blocked while the process runs.
func runProcess(_ path: String, arguments: [String], timeout: Duration) async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let box = ProcessBox(process)
    let resumed = OSAllocatedUnfairLock(initialState: false)
    let timeoutTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
        let finish: @Sendable (String?) -> Void = { result in
            let first = resumed.withLock { done in
                defer { done = true }
                return !done
            }
            guard first else { return }
            timeoutTask.withLock { $0?.cancel() }
            continuation.resume(returning: result)
        }

        process.terminationHandler = { finished in
            // The output of `top` for one pid is far smaller than a pipe buffer, so reading
            // after exit cannot deadlock.
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard finished.terminationReason == .exit, finished.terminationStatus == 0 else {
                finish(nil)
                return
            }
            finish(String(decoding: data, as: UTF8.self))
        }

        do {
            try process.run()
        } catch {
            finish(nil)
            return
        }

        let task = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            if box.process.isRunning { box.process.terminate() }
            finish(nil)
        }
        timeoutTask.withLock { $0 = task }
    }
}

/// `Process` is not Sendable, but `isRunning` and `terminate()` are safe to call from any thread.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
