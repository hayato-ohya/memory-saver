import Foundation

// MARK: - System

/// Values match `sysctl kern.memorystatus_vm_pressure_level`.
public enum MemoryPressureLevel: Int, Sendable, Codable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SystemMemorySnapshot: Sendable, Codable, Equatable {
    public var timestamp: Date
    /// Physical memory installed (`hw.memsize`).
    public var totalBytes: UInt64
    /// What Activity Monitor calls "Memory Used": app memory + wired + compressed.
    public var usedBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    /// File-backed and purgeable pages the OS can drop on its own.
    public var cachedBytes: UInt64
    public var freeBytes: UInt64
    public var swapUsedBytes: UInt64
    public var pressure: MemoryPressureLevel

    public init(
        timestamp: Date, totalBytes: UInt64, usedBytes: UInt64, wiredBytes: UInt64,
        compressedBytes: UInt64, cachedBytes: UInt64, freeBytes: UInt64,
        swapUsedBytes: UInt64, pressure: MemoryPressureLevel
    ) {
        self.timestamp = timestamp
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.freeBytes = freeBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }
}

// MARK: - Processes and apps

/// One process owned by the current user.
public struct ProcessSample: Sendable, Codable, Equatable {
    public var pid: Int32
    public var parentPID: Int32
    /// Full executable name, not the 32-character name the kernel keeps.
    public var name: String
    public var executablePath: String?
    /// `ri_phys_footprint`: the number Activity Monitor shows as "Memory". Not RSS.
    public var footprintBytes: UInt64
    public var startTime: Date?
    /// The process the system holds responsible for this one (what Activity Monitor groups by).
    /// nil when unknown. Equal to `pid` for a process that is responsible for itself.
    public var responsiblePID: Int32?
    /// Short role for helper processes that share one name, e.g. "renderer" or "gpu-process".
    public var detail: String?

    public init(
        pid: Int32, parentPID: Int32, name: String, executablePath: String?,
        footprintBytes: UInt64, startTime: Date?, responsiblePID: Int32? = nil, detail: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.footprintBytes = footprintBytes
        self.startTime = startTime
        self.responsiblePID = responsiblePID
        self.detail = detail
    }
}

/// A GUI application as reported by NSWorkspace. Input to app grouping, kept as a plain
/// value so grouping stays a pure function.
public struct RunningAppInfo: Sendable, Codable, Equatable {
    public var pid: Int32
    public var bundleIdentifier: String?
    public var displayName: String
    public var bundleURL: URL?
    public var launchDate: Date?

    public init(
        pid: Int32, bundleIdentifier: String?, displayName: String, bundleURL: URL?,
        launchDate: Date?
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.launchDate = launchDate
    }
}

/// An app with all of its helper processes folded in (e.g. every Brave renderer under "Brave Browser").
public struct AppMemoryUsage: Sendable, Codable, Equatable, Identifiable {
    /// Stable across relaunches: bundle identifier, else executable path, else name.
    public var id: String
    public var displayName: String
    public var bundleIdentifier: String?
    public var bundleURL: URL?
    public var mainPID: Int32
    /// Sum over `processes`.
    public var footprintBytes: UInt64
    public var launchDate: Date?
    /// Main process first, then helpers by footprint, descending.
    public var processes: [ProcessSample]
    /// False for system agents (Dock, Finder, loginwindow, Control Center...) and anything
    /// without an app bundle to reopen. The UI offers relaunch only when this is true.
    public var canRelaunch: Bool

    public init(
        id: String, displayName: String, bundleIdentifier: String?, bundleURL: URL?,
        mainPID: Int32, footprintBytes: UInt64, launchDate: Date?, processes: [ProcessSample],
        canRelaunch: Bool = true
    ) {
        self.canRelaunch = canRelaunch
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.mainPID = mainPID
        self.footprintBytes = footprintBytes
        self.launchDate = launchDate
        self.processes = processes
    }
}

// MARK: - Windows

/// Per-process window totals, used to rank likely contributors to WindowServer memory.
/// This is an estimate: there is no public per-app breakdown of WindowServer memory.
public struct WindowFootprint: Sendable, Codable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var ownerName: String
    public var windowCount: Int
    /// Sum of width x height x scale^2 x 4 bytes over the process's windows.
    public var estimatedBackingBytes: UInt64

    public init(pid: Int32, ownerName: String, windowCount: Int, estimatedBackingBytes: UInt64) {
        self.pid = pid
        self.ownerName = ownerName
        self.windowCount = windowCount
        self.estimatedBackingBytes = estimatedBackingBytes
    }
}

// MARK: - Combined snapshot

public struct MemorySnapshot: Sendable, Codable, Equatable {
    public var timestamp: Date
    public var system: SystemMemorySnapshot
    /// nil when the value could not be read.
    public var windowServerBytes: UInt64?
    /// Sorted by footprint, descending.
    public var apps: [AppMemoryUsage]
    /// Sorted by estimated backing bytes, descending.
    public var windows: [WindowFootprint]

    public init(
        timestamp: Date, system: SystemMemorySnapshot, windowServerBytes: UInt64?,
        apps: [AppMemoryUsage], windows: [WindowFootprint]
    ) {
        self.timestamp = timestamp
        self.system = system
        self.windowServerBytes = windowServerBytes
        self.apps = apps
        self.windows = windows
    }
}

// MARK: - History

public enum SeriesKey: Sendable, Hashable, Codable {
    case systemUsed
    case windowServer
    case app(id: String)
}

public struct TrendPoint: Sendable, Codable, Equatable {
    public var timestamp: Date
    public var bytes: UInt64

    public init(timestamp: Date, bytes: UInt64) {
        self.timestamp = timestamp
        self.bytes = bytes
    }
}

// MARK: - Baselines

/// The footprint growth is measured against.
public struct Baseline: Sendable, Codable, Equatable {
    public enum Origin: String, Sendable, Codable {
        /// Measured shortly after the app launched (or, for WindowServer, after boot).
        case afterLaunch
        /// The app was already running when monitoring began, so this is its size when first seen.
        case firstSeen
    }

    public var bytes: UInt64
    public var origin: Origin

    public init(bytes: UInt64, origin: Origin) {
        self.bytes = bytes
        self.origin = origin
    }
}

// MARK: - Recommendations

public struct AdvisorSettings: Sendable, Codable, Equatable {
    /// An app must use at least this much to be a relaunch candidate.
    public var appFootprintThresholdBytes: UInt64
    /// ...and have grown to at least this multiple of its post-launch baseline.
    public var appGrowthFactor: Double
    /// WindowServer is flagged once it exceeds its baseline by this much.
    public var windowServerGrowthThresholdBytes: UInt64
    /// How many window owners to list as WindowServer suspects.
    public var windowServerSuspectCount: Int
    /// Never recommend relaunching these. Matched against an app's bundle identifier, or its id
    /// when it has no bundle identifier.
    public var excludedAppIDs: Set<String>

    public init(
        appFootprintThresholdBytes: UInt64 = 2 << 30,
        appGrowthFactor: Double = 1.5,
        windowServerGrowthThresholdBytes: UInt64 = 1 << 30,
        windowServerSuspectCount: Int = 3,
        excludedAppIDs: Set<String> = []
    ) {
        self.appFootprintThresholdBytes = appFootprintThresholdBytes
        self.appGrowthFactor = appGrowthFactor
        self.windowServerGrowthThresholdBytes = windowServerGrowthThresholdBytes
        self.windowServerSuspectCount = windowServerSuspectCount
        self.excludedAppIDs = excludedAppIDs
    }
}

public enum Recommendation: Sendable, Equatable, Identifiable {
    case relaunchApp(app: AppMemoryUsage, baseline: Baseline)
    case windowServerBloat(currentBytes: UInt64, baseline: Baseline, suspects: [WindowFootprint])

    public var id: String {
        switch self {
        case .relaunchApp(let app, _): "relaunch:\(app.id)"
        case .windowServerBloat: "windowserver"
        }
    }
}
