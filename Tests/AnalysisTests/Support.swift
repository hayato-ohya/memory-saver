import Foundation
import MemorySaverCore

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
let MB: UInt64 = 1 << 20
let GB: UInt64 = 1 << 30

func minutes(_ m: Double, after date: Date = t0) -> Date { date.addingTimeInterval(m * 60) }

func app(
    _ id: String, bytes: UInt64, launch: Date? = t0, canRelaunch: Bool = true
) -> AppMemoryUsage {
    AppMemoryUsage(
        id: id, displayName: id, bundleIdentifier: id, bundleURL: nil, mainPID: 1,
        footprintBytes: bytes, launchDate: launch, processes: [], canRelaunch: canRelaunch)
}

func window(_ pid: Int32, _ bytes: UInt64) -> WindowFootprint {
    WindowFootprint(pid: pid, ownerName: "p\(pid)", windowCount: 1, estimatedBackingBytes: bytes)
}

func snapshot(
    at date: Date, used: UInt64 = 8 * GB, windowServer: UInt64? = nil,
    apps: [AppMemoryUsage] = [], windows: [WindowFootprint] = []
) -> MemorySnapshot {
    MemorySnapshot(
        timestamp: date,
        system: SystemMemorySnapshot(
            timestamp: date, totalBytes: 16 * GB, usedBytes: used, wiredBytes: 0,
            compressedBytes: 0, cachedBytes: 0, freeBytes: 0, swapUsedBytes: 0, pressure: .normal),
        windowServerBytes: windowServer, apps: apps, windows: windows)
}
