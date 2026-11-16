import Darwin
import Foundation
import MemorySaverCore

public struct ProcessSampler: ProcessSampling {
    public init() {}

    public func sample() throws -> [ProcessSample] {
        allPIDs().compactMap(Self.sample(pid:))
    }

    /// Returns nil for processes we may not read (other users) or that exited meanwhile.
    static func sample(pid: Int32) -> ProcessSample? {
        guard pid > 0, let footprint = footprint(pid: pid) else { return nil }

        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { return nil }

        // pbi_name is cut at 32 characters, so prefer the executable's file name.
        let path = executablePath(pid: pid)
        var name = path.map { ($0 as NSString).lastPathComponent } ?? ""
        if name.isEmpty { name = string(fromCCharTuple: info.pbi_name) }
        if name.isEmpty { name = string(fromCCharTuple: info.pbi_comm) }

        let start = info.pbi_start_tvsec > 0
            ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            : nil

        return ProcessSample(
            pid: pid,
            parentPID: Int32(bitPattern: info.pbi_ppid),
            name: name,
            executablePath: path,
            footprintBytes: footprint,
            startTime: start,
            responsiblePID: responsiblePID(pid: pid),
            detail: path.flatMap { isNestedHelper(path: $0) ? helperRole(pid: pid) : nil }
        )
    }

    static func responsiblePID(pid: Int32) -> Int32? {
        let responsible = responsibility_get_pid_responsible_for_pid(pid)
        return responsible > 0 ? responsible : nil
    }

    /// An executable inside an app nested in another app, like Chromium and Electron helpers.
    /// Only these get their arguments read, since that costs a sysctl per process.
    static func isNestedHelper(path: String) -> Bool {
        path.split(separator: "/").filter { $0.hasSuffix(".app") }.count >= 2
    }

    static func helperRole(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return helperRole(procArgs: buffer.prefix(size))
    }

    /// Parses a `KERN_PROCARGS2` buffer (argc as Int32, executable path, NUL padding, then argc
    /// NUL-terminated arguments, then the environment) into a short Chromium helper role such as
    /// "renderer" or "utility (NetworkService)". nil if there is no `--type=` or the buffer is
    /// malformed. The environment is never read.
    static func helperRole(procArgs: some Collection<UInt8>) -> String? {
        let bytes = Array(procArgs)
        guard bytes.count >= 4 else { return nil }
        let argc = bytes[0..<4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        var index = 4
        // Executable path, then the NULs that pad it.
        guard let pathEnd = bytes[index...].firstIndex(of: 0) else { return nil }
        index = pathEnd
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var type: String?
        var subType: String?
        for _ in 0..<argc {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0) else { return nil }
            let argument = String(decoding: bytes[index..<end], as: UTF8.self)
            index = end + 1
            if argument.hasPrefix("--type=") {
                type = String(argument.dropFirst("--type=".count))
            } else if argument.hasPrefix("--utility-sub-type=") {
                subType = argument.dropFirst("--utility-sub-type=".count)
                    .split(separator: ".").last.map(String.init)
            }
        }
        guard let type, !type.isEmpty else { return nil }
        if let subType, !subType.isEmpty { return "\(type) (\(subType))" }
        return type
    }

    static func footprint(pid: Int32) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    static func executablePath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a macro Swift does not import.
        let size = 4 * Int(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: size)
        let length = proc_pidpath(pid, &buffer, UInt32(size))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// Private libsystem call Activity Monitor uses to group processes. Returns -1 on failure.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// All pids on the system, including other users' processes.
func allPIDs() -> [Int32] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    // Leave room for processes started between the two calls.
    var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
    let count = pids.withUnsafeMutableBytes {
        proc_listallpids($0.baseAddress, Int32($0.count))
    }
    guard count > 0 else { return [] }
    return Array(pids.prefix(Int(count)))
}

