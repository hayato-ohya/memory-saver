import Foundation
import Testing
import MemorySaverCore
@testable import Analysis

private struct FakeStore: TrendStoring {
    var appBaselines: [String: UInt64] = [:]
    var windowServer: UInt64?

    private func after(_ bytes: UInt64?) -> Baseline? {
        bytes.map { Baseline(bytes: $0, origin: .afterLaunch) }
    }

    func record(_ snapshot: MemorySnapshot) throws {}
    func appBaseline(appID: String, launchDate: Date?) throws -> Baseline? { after(appBaselines[appID]) }
    func windowServerBaseline(since bootTime: Date) throws -> Baseline? { after(windowServer) }
    func history(series: SeriesKey, since: Date) throws -> [TrendPoint] { [] }
    func prune(olderThan cutoff: Date) throws {}
}

struct AdvisorTests {
    private let settings = AdvisorSettings(
        appFootprintThresholdBytes: 2 * GB, appGrowthFactor: 1.5,
        windowServerGrowthThresholdBytes: GB, windowServerSuspectCount: 2, excludedAppIDs: [])

    private func advise(
        _ store: FakeStore, apps: [AppMemoryUsage] = [], windowServer: UInt64? = nil,
        windows: [WindowFootprint] = [], settings: AdvisorSettings? = nil
    ) throws -> [Recommendation] {
        try Advisor(store: store).recommendations(
            for: snapshot(at: t0, windowServer: windowServer, apps: apps, windows: windows),
            windowServerStart: t0, settings: settings ?? self.settings)
    }

    @Test func appAtExactBoundariesIsRecommended() throws {
        // Footprint == threshold and == baseline x factor.
        let exact = try advise(FakeStore(appBaselines: ["a": GB]), apps: [app("a", bytes: 2 * GB)],
                               settings: AdvisorSettings(appFootprintThresholdBytes: 2 * GB, appGrowthFactor: 2))
        #expect(exact == [.relaunchApp(app: app("a", bytes: 2 * GB), baseline: Baseline(bytes: GB, origin: .afterLaunch))])
    }

    @Test func appJustBelowThresholdsIsNotRecommended() throws {
        let store = FakeStore(appBaselines: ["a": GB])
        #expect(try advise(store, apps: [app("a", bytes: 2 * GB - 1)],
                           settings: AdvisorSettings(appFootprintThresholdBytes: 2 * GB, appGrowthFactor: 1)).isEmpty)
        #expect(try advise(store, apps: [app("a", bytes: 2 * GB)],
                           settings: AdvisorSettings(appFootprintThresholdBytes: 2 * GB, appGrowthFactor: 2.01)).isEmpty)
    }

    @Test func appWithoutBaselineIsNeverRecommended() throws {
        #expect(try advise(FakeStore(), apps: [app("a", bytes: 50 * GB)]).isEmpty)
    }

    @Test func excludedAppIsSkipped() throws {
        var excluding = settings
        excluding.excludedAppIDs = ["a"]
        let store = FakeStore(appBaselines: ["a": GB, "b": GB])
        let result = try advise(store, apps: [app("a", bytes: 5 * GB), app("b", bytes: 5 * GB)], settings: excluding)
        #expect(result.map(\.id) == ["relaunch:b"])
    }

    @Test func exclusionMatchesBundleIdentifierNotSuffixedID() throws {
        var excluding = settings
        excluding.excludedAppIDs = ["com.example.app"]
        let store = FakeStore(appBaselines: ["com.example.app#42": GB, "other": GB])
        let second = AppMemoryUsage(
            id: "com.example.app#42", displayName: "App", bundleIdentifier: "com.example.app",
            bundleURL: nil, mainPID: 42, footprintBytes: 5 * GB, launchDate: t0, processes: [])
        let result = try advise(store, apps: [second, app("other", bytes: 5 * GB)], settings: excluding)
        #expect(result.map(\.id) == ["relaunch:other"])

        // Without a bundle identifier the id is what is matched.
        var noBundle = app("path/tool", bytes: 5 * GB)
        noBundle.bundleIdentifier = nil
        excluding.excludedAppIDs = ["path/tool"]
        #expect(try advise(FakeStore(appBaselines: ["path/tool": GB]), apps: [noBundle], settings: excluding).isEmpty)
    }

    @Test func appThatCannotRelaunchIsNeverRecommended() throws {
        var agent = app("a", bytes: 50 * GB)
        agent.canRelaunch = false
        #expect(try advise(FakeStore(appBaselines: ["a": GB]), apps: [agent]).isEmpty)
    }

    @Test func fastGrowthAfterLaunchIsNotRecommendedBeforeBaselineSettles() throws {
        let store = try TrendStore(inMemory: true)
        let growth: [Double: UInt64] = [0: 400 * MB, 1: 1 * GB, 2: 1700 * MB, 3: 2 * GB, 4: 2600 * MB]
        for m in 0...4 {
            try store.record(snapshot(at: minutes(Double(m)), apps: [app("a", bytes: growth[Double(m)]!)]))
        }
        let current = app("a", bytes: 2600 * MB)
        let result = try Advisor(store: store).recommendations(
            for: snapshot(at: minutes(4), apps: [current]), windowServerStart: t0,
            settings: AdvisorSettings(appFootprintThresholdBytes: 2 * GB, appGrowthFactor: 1.5))
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == nil)
        #expect(result.isEmpty)
    }

    @Test func baselineLargerThanCurrentDoesNotUnderflow() throws {
        let store = FakeStore(appBaselines: ["a": 10 * GB], windowServer: 10 * GB)
        let low = AdvisorSettings(
            appFootprintThresholdBytes: 0, appGrowthFactor: 0, windowServerGrowthThresholdBytes: 0)
        #expect(try advise(store, apps: [app("a", bytes: 3 * GB)], windowServer: 3 * GB, settings: low).isEmpty)
    }

    @Test func hugeThresholdDoesNotOverflow() throws {
        let store = FakeStore(windowServer: UInt64.max - 10)
        var huge = settings
        huge.windowServerGrowthThresholdBytes = UInt64.max
        #expect(try advise(store, windowServer: UInt64.max, settings: huge).isEmpty)
    }

    @Test func windowServerBoundary() throws {
        let store = FakeStore(windowServer: GB)
        #expect(try advise(store, windowServer: 2 * GB - 1).isEmpty)
        #expect(try advise(store, windowServer: nil).isEmpty)
        #expect(try advise(FakeStore(), windowServer: 20 * GB).isEmpty)
        let result = try advise(store, windowServer: 2 * GB)
        #expect(result == [.windowServerBloat(currentBytes: 2 * GB, baseline: Baseline(bytes: GB, origin: .afterLaunch), suspects: [])])
    }

    @Test func windowServerSuspectsAreTopN() throws {
        let windows = [window(1, 300 * MB), window(2, 200 * MB), window(3, 100 * MB)]
        let store = FakeStore(windowServer: GB)
        let result = try advise(store, windowServer: 3 * GB, windows: windows)
        #expect(result == [.windowServerBloat(
            currentBytes: 3 * GB, baseline: Baseline(bytes: GB, origin: .afterLaunch), suspects: Array(windows.prefix(2)))])

        var zero = settings
        zero.windowServerSuspectCount = 0
        let none = try advise(store, windowServer: 3 * GB, windows: windows, settings: zero)
        #expect(none == [.windowServerBloat(currentBytes: 3 * GB, baseline: Baseline(bytes: GB, origin: .afterLaunch), suspects: [])])

        var many = settings
        many.windowServerSuspectCount = 10
        let all = try advise(store, windowServer: 3 * GB, windows: windows, settings: many)
        #expect(all == [.windowServerBloat(currentBytes: 3 * GB, baseline: Baseline(bytes: GB, origin: .afterLaunch), suspects: windows)])
    }

    @Test func orderingWindowServerFirstThenByReclaimableDescending() throws {
        let store = FakeStore(
            appBaselines: ["small": GB, "big": GB, "mid": GB, "unbloated": 4 * GB], windowServer: GB)
        // Snapshot order is by footprint, which differs from reclaimable order.
        let apps = [
            app("unbloated", bytes: 5 * GB), app("small", bytes: 3 * GB),
            app("big", bytes: 3 * GB + 1), app("mid", bytes: 3 * GB),
        ]
        let result = try advise(store, apps: apps, windowServer: 5 * GB)
        #expect(result.map(\.id) == ["windowserver", "relaunch:big", "relaunch:small", "relaunch:mid"])
    }

    @Test func realStoreEndToEnd() throws {
        let store = try TrendStore(inMemory: true)
        for m in 1...30 {
            try store.record(snapshot(
                at: minutes(Double(m)), windowServer: 500 * MB,
                apps: [app("a", bytes: m <= 20 ? GB : 4 * GB)]))
        }
        let current = app("a", bytes: 4 * GB)
        let result = try Advisor(store: store).recommendations(
            for: snapshot(at: minutes(31), windowServer: 500 * MB, apps: [current]),
            windowServerStart: t0, settings: settings)
        #expect(result == [.relaunchApp(app: current, baseline: Baseline(bytes: GB, origin: .afterLaunch))])
    }
}
