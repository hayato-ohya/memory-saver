import CoreGraphics
import Foundation
import MemorySaverCore

/// Estimates each process's share of WindowServer memory from the size of its windows.
/// Only owner pid, owner name and bounds are read, which needs no Screen Recording permission.
public struct WindowAttributor: WindowAttributing {
    public init() {}

    public func sample() -> [WindowFootprint] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let windows = list.compactMap { entry -> WindowInfo? in
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            return WindowInfo(pid: pid, ownerName: owner, bounds: bounds)
        }
        return aggregateWindows(
            windows,
            displays: activeDisplays(),
            excludingPIDs: Set([ProcessInfo.processInfo.processIdentifier, findWindowServerPID()].compactMap { $0 })
        )
    }
}

public struct WindowInfo: Sendable, Equatable {
    public var pid: Int32
    public var ownerName: String
    /// In points, global display coordinates (as `CGDisplayBounds`).
    public var bounds: CGRect

    public init(pid: Int32, ownerName: String, bounds: CGRect) {
        self.pid = pid
        self.ownerName = ownerName
        self.bounds = bounds
    }
}

public struct DisplayInfo: Sendable, Equatable {
    /// In points, global display coordinates.
    public var bounds: CGRect
    /// Pixels per point.
    public var scale: Double
    public var isMain: Bool

    public init(bounds: CGRect, scale: Double, isMain: Bool) {
        self.bounds = bounds
        self.scale = scale
        self.isMain = isMain
    }
}

/// Larger than any real window; bigger bounds are placeholders, not backing stores.
let maxWindowDimension: CGFloat = 16_384

/// Groups windows by owner pid. Each window is scaled by the display it mostly overlaps,
/// or by the main display when it is off screen.
public func aggregateWindows(
    _ windows: [WindowInfo], displays: [DisplayInfo], excludingPIDs: Set<Int32>
) -> [WindowFootprint] {
    let fallbackScale = displays.first(where: \.isMain)?.scale ?? displays.first?.scale ?? 2

    var totals: [Int32: WindowFootprint] = [:]
    for window in windows {
        let size = window.bounds.size
        guard !excludingPIDs.contains(window.pid),
              size.width >= 1, size.height >= 1,
              size.width <= maxWindowDimension, size.height <= maxWindowDimension
        else { continue }

        var scale = fallbackScale
        var bestOverlap: CGFloat = 0
        for display in displays {
            let overlap = display.bounds.intersection(window.bounds)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestOverlap {
                bestOverlap = area
                scale = display.scale
            }
        }

        let bytes = UInt64((Double(size.width) * Double(size.height) * scale * scale * 4).rounded())
        var entry = totals[window.pid] ?? WindowFootprint(
            pid: window.pid, ownerName: window.ownerName, windowCount: 0, estimatedBackingBytes: 0)
        entry.windowCount += 1
        entry.estimatedBackingBytes += bytes
        totals[window.pid] = entry
    }
    return totals.values.sorted {
        ($0.estimatedBackingBytes, $1.pid) > ($1.estimatedBackingBytes, $0.pid)
    }
}

/// Active displays with their backing scale. CGDisplay functions are thread-safe, unlike NSScreen.
func activeDisplays() -> [DisplayInfo] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    let main = CGMainDisplayID()
    return ids.prefix(Int(count)).map { id in
        let bounds = CGDisplayBounds(id)
        var scale = 1.0
        if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
            scale = Double(mode.pixelWidth) / Double(mode.width)
        }
        return DisplayInfo(bounds: bounds, scale: scale, isMain: id == main)
    }
}
