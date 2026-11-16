import Foundation
import MemorySaverCore

/// Runs the samplers on a timer, records history, and publishes each result.
actor MonitorEngine {
    struct Update: Sendable {
        var snapshot: MemorySnapshot?
        var recommendations: [Recommendation] = []
        var windowServerBaseline: Baseline?
        var appBaselines: [String: Baseline] = [:]
        var error: String?
    }

    struct Dependencies: Sendable {
        var system: any SystemSampling
        var processes: any ProcessSampling
        var windowServer: any WindowServerSampling
        var runningApps: any RunningAppProviding
        var grouper: any AppGrouping
        var windows: any WindowAttributing
        var store: any TrendStoring
        var advisor: any Advising
        /// Used for the WindowServer baseline when WindowServer's own start time cannot be read.
        var bootTime: Date
    }

    static let historyRetention: TimeInterval = 7 * 24 * 3600
    private static let pruneInterval: TimeInterval = 3600
    /// Reading WindowServer means running `top`, which costs far more CPU than everything else
    /// in a sample, and the value moves slowly.
    private static let windowServerInterval: TimeInterval = 300

    private let deps: Dependencies
    private let settings: @Sendable () async -> AdvisorSettings
    private let onUpdate: @Sendable (Update) async -> Void
    private var loop: Task<Void, Never>?
    private var lastPrune = Date.distantPast
    private var windowServerBytes: UInt64?
    /// WindowServer is recreated at every login, so its baseline starts when it does.
    private var windowServerStart: Date?
    private var lastWindowServerSample = Date.distantPast
    private var isSampling = false

    init(
        dependencies: Dependencies,
        settings: @escaping @Sendable () async -> AdvisorSettings,
        onUpdate: @escaping @Sendable (Update) async -> Void
    ) {
        self.deps = dependencies
        self.settings = settings
        self.onUpdate = onUpdate
    }

    func start(interval: Duration = .seconds(60)) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(forceWindowServer: false)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Samples once, outside the timer. Skipped if a sample is already in flight.
    func refreshNow() async {
        await tick(forceWindowServer: true)
    }

    private func tick(forceWindowServer: Bool) async {
        // The actor is re-entrant across the awaits below; one sample at a time is enough.
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }

        let update = await sampleOnce(forceWindowServer: forceWindowServer)
        await onUpdate(update)
    }

    /// Two running instances of one app share a bundle identifier. Ids must be unique for the
    /// UI and for history, so every instance except the earliest-launched gets its pid appended.
    /// The choice must not depend on footprint order, or the instances would swap ids (and
    /// with them their history) whenever one overtakes the other.
    static func uniquingIDs(_ apps: [AppMemoryUsage]) -> [AppMemoryUsage] {
        func isEarlier(_ a: AppMemoryUsage, than b: AppMemoryUsage) -> Bool {
            let (da, db) = (a.launchDate ?? .distantFuture, b.launchDate ?? .distantFuture)
            return da != db ? da < db : a.mainPID < b.mainPID
        }
        var primary: [String: AppMemoryUsage] = [:]
        for app in apps {
            if let current = primary[app.id], !isEarlier(app, than: current) { continue }
            primary[app.id] = app
        }
        return apps.map { app in
            guard primary[app.id]?.mainPID != app.mainPID else { return app }
            var copy = app
            copy.id = "\(app.id)#\(app.mainPID)"
            return copy
        }
    }

    private func sampleOnce(forceWindowServer: Bool) async -> Update {
        let now = Date()
        let snapshot: MemorySnapshot
        do {
            let system = try deps.system.sample()
            let processes = try deps.processes.sample()
            let apps = Self.uniquingIDs(
                deps.grouper.group(processes: processes, apps: deps.runningApps.runningApps()))
            if forceWindowServer || now.timeIntervalSince(lastWindowServerSample) >= Self.windowServerInterval {
                windowServerBytes = await deps.windowServer.sample()
                windowServerStart = await deps.windowServer.startTime() ?? windowServerStart
                lastWindowServerSample = now
            }
            snapshot = MemorySnapshot(
                timestamp: now, system: system, windowServerBytes: windowServerBytes,
                apps: apps, windows: deps.windows.sample())
        } catch {
            return Update(error: tr(.errorMemoryReadFailed, error.localizedDescription))
        }

        // History problems must not hide the live numbers, so they are reported alongside them.
        var update = Update(snapshot: snapshot)
        do {
            try deps.store.record(snapshot)
            if now.timeIntervalSince(lastPrune) >= Self.pruneInterval {
                try deps.store.prune(olderThan: now.addingTimeInterval(-Self.historyRetention))
                lastPrune = now
            }
            let windowServerStart = windowServerStart ?? deps.bootTime
            update.windowServerBaseline = try deps.store.windowServerBaseline(since: windowServerStart)
            for app in snapshot.apps {
                if let baseline = try deps.store.appBaseline(appID: app.id, launchDate: app.launchDate) {
                    update.appBaselines[app.id] = baseline
                }
            }
            update.recommendations = try deps.advisor.recommendations(
                for: snapshot, windowServerStart: windowServerStart, settings: await settings())
        } catch {
            update.error = tr(.errorHistoryAccessFailed, error.localizedDescription)
        }
        return update
    }
}
