import Foundation

public protocol SystemSampling: Sendable {
    func sample() throws -> SystemMemorySnapshot
}

public protocol ProcessSampling: Sendable {
    /// Processes of the current user. Processes that cannot be read are skipped, not errors.
    func sample() throws -> [ProcessSample]
}

public protocol WindowServerSampling: Sendable {
    /// WindowServer's memory footprint in bytes, or nil if it cannot be read.
    func sample() async -> UInt64?
    /// When the running WindowServer started, or nil if it cannot be read.
    func startTime() async -> Date?
}

public protocol RunningAppProviding: Sendable {
    func runningApps() -> [RunningAppInfo]
}

public protocol AppGrouping: Sendable {
    /// Folds helper processes into their owning app. Result is sorted by footprint, descending.
    /// Only real app bundles are owners; XPC services, extensions and nested helper apps that
    /// the system also lists as running applications are members of the app responsible for
    /// them. Processes that belong to no app are dropped.
    func group(processes: [ProcessSample], apps: [RunningAppInfo]) -> [AppMemoryUsage]
}

public protocol WindowAttributing: Sendable {
    /// Per-process window totals, sorted by estimated backing bytes, descending.
    func sample() -> [WindowFootprint]
}

public protocol TrendStoring: Sendable {
    func record(_ snapshot: MemorySnapshot) throws
    /// Baseline for this run of the app (identified by id + launch date). nil until the value
    /// is settled, so a baseline never moves once it has been returned.
    func appBaseline(appID: String, launchDate: Date?) throws -> Baseline?
    /// Baseline for the WindowServer that started at `windowServerStart`. nil until settled.
    func windowServerBaseline(since windowServerStart: Date) throws -> Baseline?
    func history(series: SeriesKey, since: Date) throws -> [TrendPoint]
    func prune(olderThan cutoff: Date) throws
}

public protocol Advising: Sendable {
    func recommendations(
        for snapshot: MemorySnapshot, windowServerStart: Date, settings: AdvisorSettings
    ) throws -> [Recommendation]
}
