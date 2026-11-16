import Darwin
import Foundation
import MemorySaverCore

public struct SystemSampler: SystemSampling {
    // mach_host_self() adds a send-right reference on every call, so fetch it once.
    private static let host: mach_port_t = mach_host_self()

    public init() {}

    public func sample() throws -> SystemMemorySnapshot {
        let host = Self.host

        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS, pageSize > 0 else {
            throw SamplingError.hostStatistics(pageResult)
        }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw SamplingError.hostStatistics(result) }

        let page = UInt64(pageSize)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appMemory = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        // Like vm_stat, free_count includes speculative pages; report them as not free.
        let freePages = UInt64(stats.free_count) - min(UInt64(stats.free_count), UInt64(stats.speculative_count))

        let total: UInt64 = try sysctlValue("hw.memsize")
        let swap: xsw_usage = try sysctlValue("vm.swapusage")

        return SystemMemorySnapshot(
            timestamp: Date(),
            totalBytes: total,
            usedBytes: appMemory + wired + compressed,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached,
            freeBytes: freePages * page,
            swapUsedBytes: swap.xsu_used,
            pressure: Self.pressureLevel()
        )
    }

    static func pressureLevel() -> MemoryPressureLevel {
        guard let raw = try? sysctlValue("kern.memorystatus_vm_pressure_level", as: Int32.self) else {
            return .normal
        }
        return MemoryPressureLevel(rawValue: Int(raw)) ?? .normal
    }
}
