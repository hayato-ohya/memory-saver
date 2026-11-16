import Foundation
import Testing
import MemorySaverCore
@testable import Analysis

struct TrendStoreTests {
    /// Records one sample per minute for `minute in range`, with the app's size given by `bytes`.
    private func recordApp(
        _ store: TrendStore, id: String = "a", launch: Date? = t0, minutes range: ClosedRange<Int>,
        bytes: (Int) -> UInt64
    ) throws {
        for m in range {
            try store.record(snapshot(
                at: minutes(Double(m)), apps: [app(id, bytes: bytes(m), launch: launch)]))
        }
    }

    @Test func recordAndHistoryRoundTripInOrder() throws {
        let store = try TrendStore(inMemory: true)
        // Recorded out of order on purpose.
        for m in [3, 1, 2] {
            try store.record(snapshot(
                at: minutes(Double(m)), used: UInt64(m) * GB, windowServer: UInt64(m) * MB,
                apps: [app("a", bytes: UInt64(m) * 100 * MB)]))
        }
        let system = try store.history(series: .systemUsed, since: t0)
        #expect(system.map(\.bytes) == [1 * GB, 2 * GB, 3 * GB])
        #expect(system.map(\.timestamp) == [minutes(1), minutes(2), minutes(3)])
        #expect(try store.history(series: .windowServer, since: t0).map(\.bytes) == [MB, 2 * MB, 3 * MB])
        #expect(try store.history(series: .app(id: "a"), since: minutes(2)).map(\.bytes) == [200 * MB, 300 * MB])
        #expect(try store.history(series: .app(id: "missing"), since: t0).isEmpty)
    }

    @Test func nilWindowServerIsSkipped() throws {
        let store = try TrendStore(inMemory: true)
        try store.record(snapshot(at: minutes(1), windowServer: nil))
        try store.record(snapshot(at: minutes(2), windowServer: 5 * MB))
        #expect(try store.history(series: .windowServer, since: t0).map(\.bytes) == [5 * MB])
        #expect(try store.history(series: .systemUsed, since: t0).count == 2)
    }

    @Test func appHistoryMergesRuns() throws {
        let store = try TrendStore(inMemory: true)
        try recordApp(store, launch: t0, minutes: 1...2) { _ in 1 * GB }
        try recordApp(store, launch: minutes(2.5), minutes: 3...4) { _ in 2 * GB }
        let points = try store.history(series: .app(id: "a"), since: t0)
        #expect(points.map(\.bytes) == [GB, GB, 2 * GB, 2 * GB])
    }

    @Test func baselineUsesFiveToTwentyMinuteWindow() throws {
        let store = try TrendStore(inMemory: true)
        // Early growth spike, settled value 1 GB between minutes 5 and 20, later bloat.
        try recordApp(store, minutes: 1...30) { m in
            switch m {
            case ..<5: 300 * MB
            case 5...20: GB
            default: 4 * GB
            }
        }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: GB, origin: .afterLaunch))
    }

    @Test func baselineWindowIsInclusiveAtBothEnds() throws {
        let store = try TrendStore(inMemory: true)
        let bytes: [Int: UInt64] = [1: 9 * GB, 2: 9 * GB, 3: 9 * GB, 4: 9 * GB, 5: GB, 20: 3 * GB, 21: 9 * GB, 22: 9 * GB]
        for (m, value) in bytes.sorted(by: { $0.key < $1.key }) {
            try store.record(snapshot(at: minutes(Double(m)), apps: [app("a", bytes: value)]))
        }
        // Only minutes 5 and 20 are in the window: median is their midpoint.
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: 2 * GB, origin: .afterLaunch))
    }

    @Test func baselineMedianOfEvenCountAverages() throws {
        let store = try TrendStore(inMemory: true)
        try recordApp(store, minutes: 1...20) { m in m % 2 == 0 ? 100 * MB : 200 * MB }
        // Window minutes 5...20 has 8 values of each.
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: 150 * MB, origin: .afterLaunch))
    }

    @Test func baselineFallsBackToFirstTenSamples() throws {
        let store = try TrendStore(inMemory: true)
        // Monitor started 2 hours after launch: nothing falls in the 5-20 minute window.
        let start = 120
        try recordApp(store, minutes: start...(start + 30)) { m in
            m < start + 10 ? 500 * MB : 3 * GB
        }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: 500 * MB, origin: .firstSeen))
    }

    @Test func baselineNilUntilWindowCloses() throws {
        let store = try TrendStore(inMemory: true)
        // Plenty of samples, some already inside the window, but the window is still open.
        try recordApp(store, minutes: 1...19) { _ in GB }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == nil)
        try recordApp(store, minutes: 20...20) { _ in GB }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: GB, origin: .afterLaunch))
        #expect(try store.appBaseline(appID: "unknown", launchDate: t0) == nil)
    }

    @Test func baselineNilBeforeTenSamplesWhenLate() throws {
        let store = try TrendStore(inMemory: true)
        try recordApp(store, minutes: 120...128) { _ in GB }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == nil)
        try recordApp(store, minutes: 129...129) { _ in GB }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: GB, origin: .firstSeen))
    }

    @Test func fastGrowthDuringStartupYieldsNoBaseline() throws {
        let store = try TrendStore(inMemory: true)
        try recordApp(store, minutes: 0...4) { m in UInt64(400 + m * 550) * MB }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == nil)
        // Not even once ten start-up samples exist: the window has not been reached.
        try recordApp(store, minutes: 0...4) { m in UInt64(400 + m * 550) * MB + 1 }
        for s in 0..<10 {
            try store.record(snapshot(at: minutes(4.5 + Double(s) / 100), apps: [app("a", bytes: 3 * GB)]))
        }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == nil)
    }

    @Test func baselineNeverChangesOnceReturned() throws {
        let store = try TrendStore(inMemory: true)
        try recordApp(store, minutes: 1...20) { _ in GB }
        let first = try store.appBaseline(appID: "a", launchDate: t0)
        try recordApp(store, minutes: 21...60) { _ in 5 * GB }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == first)

        let late = try TrendStore(inMemory: true)
        try recordApp(late, minutes: 200...209) { _ in GB }
        let lateFirst = try late.appBaseline(appID: "a", launchDate: t0)
        try recordApp(late, minutes: 210...260) { _ in 5 * GB }
        // Even if a typical baseline appears afterwards.
        try recordApp(late, launch: minutes(300), minutes: 301...330) { _ in 700 * MB }
        #expect(try late.appBaseline(appID: "a", launchDate: t0) == lateFirst)
        #expect(lateFirst == Baseline(bytes: GB, origin: .firstSeen))
    }

    @Test func lateRunUsesTypicalBaselineFromEarlierRun() throws {
        let store = try TrendStore(inMemory: true)
        let second = minutes(1000)
        try recordApp(store, launch: t0, minutes: 1...30) { _ in 600 * MB }
        // Second run is first seen two days after launch, at a bloated size.
        try recordApp(store, launch: second, minutes: 3000...3015) { _ in 3 * GB }
        #expect(try store.appBaseline(appID: "a", launchDate: second)
            == Baseline(bytes: 600 * MB, origin: .afterLaunch))
        // Other apps are unaffected.
        try recordApp(store, id: "b", launch: second, minutes: 3000...3015) { _ in 3 * GB }
        #expect(try store.appBaseline(appID: "b", launchDate: second) == Baseline(bytes: 3 * GB, origin: .firstSeen))
    }

    @Test func typicalBaselineUsesMostRecentAfterLaunchRun() throws {
        let store = try TrendStore(inMemory: true)
        try recordApp(store, launch: t0, minutes: 1...30) { _ in 600 * MB }
        try recordApp(store, launch: minutes(100), minutes: 101...130) { _ in 800 * MB }
        // A substituted baseline must not become the typical one.
        try recordApp(store, launch: minutes(200), minutes: 5000...5015) { _ in 3 * GB }
        _ = try store.appBaseline(appID: "a", launchDate: minutes(200))
        try recordApp(store, launch: minutes(6000), minutes: 9000...9015) { _ in 4 * GB }
        #expect(try store.appBaseline(appID: "a", launchDate: minutes(6000))
            == Baseline(bytes: 800 * MB, origin: .afterLaunch))
    }

    @Test func typicalBaselineSurvivesPrune() throws {
        let store = try TrendStore(inMemory: true)
        try recordApp(store, launch: t0, minutes: 1...30) { _ in 600 * MB }
        try store.prune(olderThan: minutes(10_000))
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == nil)
        let late = minutes(20_000)
        try recordApp(store, launch: late, minutes: 30_000...30_012) { _ in 3 * GB }
        #expect(try store.appBaseline(appID: "a", launchDate: late)
            == Baseline(bytes: 600 * MB, origin: .afterLaunch))
        // Nil launch date also falls back to it.
        try recordApp(store, launch: nil, minutes: 30_000...30_012) { _ in 3 * GB }
        #expect(try store.appBaseline(appID: "a", launchDate: nil)
            == Baseline(bytes: 600 * MB, origin: .afterLaunch))
    }

    @Test func windowServerLateBootUsesTypicalFromEarlierBoot() throws {
        let store = try TrendStore(inMemory: true)
        let laterBoot = minutes(10_000)
        for m in 1...30 { try store.record(snapshot(at: minutes(Double(m)), windowServer: 500 * MB)) }
        #expect(try store.windowServerBaseline(since: t0) == Baseline(bytes: 500 * MB, origin: .afterLaunch))
        try store.prune(olderThan: minutes(5000))
        for m in 12_000...12_012 { try store.record(snapshot(at: minutes(Double(m)), windowServer: 3 * GB)) }
        #expect(try store.windowServerBaseline(since: laterBoot)
            == Baseline(bytes: 500 * MB, origin: .afterLaunch))
        // The earlier boot never borrows from a later one.
        let fresh = try TrendStore(inMemory: true)
        for m in 12_000...12_012 { try fresh.record(snapshot(at: minutes(Double(m)), windowServer: 3 * GB)) }
        #expect(try fresh.windowServerBaseline(since: laterBoot) == Baseline(bytes: 3 * GB, origin: .firstSeen))
    }

    @Test func windowServerBaselineNilUntilSettled() throws {
        let store = try TrendStore(inMemory: true)
        for m in 1...4 { try store.record(snapshot(at: minutes(Double(m)), windowServer: 100 * MB)) }
        for m in 5...19 { try store.record(snapshot(at: minutes(Double(m)), windowServer: 600 * MB)) }
        #expect(try store.windowServerBaseline(since: t0) == nil)
        try store.record(snapshot(at: minutes(20), windowServer: 600 * MB))
        #expect(try store.windowServerBaseline(since: t0) == Baseline(bytes: 600 * MB, origin: .afterLaunch))
    }

    // MARK: Migration

    private func legacyDatabase(at url: URL) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("""
            CREATE TABLE samples (
                series TEXT NOT NULL,
                run REAL NOT NULL,
                ts REAL NOT NULL,
                bytes INTEGER NOT NULL,
                PRIMARY KEY (series, run, ts)
            ) WITHOUT ROWID
            """)
        try db.execute("CREATE INDEX samples_series_ts ON samples (series, ts)")
        try db.execute("""
            CREATE TABLE baselines (
                series TEXT NOT NULL,
                run REAL NOT NULL,
                bytes INTEGER NOT NULL,
                PRIMARY KEY (series, run)
            ) WITHOUT ROWID
            """)
        func sample(_ series: String, _ run: Double, _ minute: Double, _ bytes: UInt64) throws {
            try db.execute(
                "INSERT INTO samples VALUES (?, ?, ?, ?)",
                [.text(series), .double(run), .double(minutes(minute).timeIntervalSince1970), .int(Int64(bytes))])
        }
        func baseline(_ series: String, _ run: Date, _ bytes: UInt64) throws {
            try db.execute(
                "INSERT INTO baselines VALUES (?, ?, ?)",
                [.text(series), .double(run.timeIntervalSince1970), .int(Int64(bytes))])
        }
        // "window": launched at t0 and watched from minute 1. "late": first seen two hours in.
        for m in 1...30 { try sample("app:window", t0.timeIntervalSince1970, Double(m), m <= 20 ? GB : 4 * GB) }
        for m in 120...140 { try sample("app:late", t0.timeIntervalSince1970, Double(m), 3 * GB) }
        for m in 1...30 { try sample("windowserver", -1, Double(m), 500 * MB) }
        try baseline("app:window", t0, GB)
        try baseline("app:late", t0, 3 * GB)
        try baseline("windowserver", t0, 500 * MB)
        // WindowServer baseline of an older boot whose samples are gone.
        try baseline("windowserver", minutes(-100_000), 900 * MB)
    }

    @Test func migratesLegacyDatabaseInPlace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-saver-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("legacy.sqlite")
        try legacyDatabase(at: url)

        for pass in 1...2 {
            let store = try TrendStore(url: url)
            #expect(try store.appBaseline(appID: "window", launchDate: t0)
                == Baseline(bytes: GB, origin: .afterLaunch), "pass \(pass)")
            #expect(try store.appBaseline(appID: "late", launchDate: t0)
                == Baseline(bytes: 3 * GB, origin: .firstSeen), "pass \(pass)")
            #expect(try store.windowServerBaseline(since: t0)
                == Baseline(bytes: 500 * MB, origin: .afterLaunch), "pass \(pass)")
            #expect(try store.windowServerBaseline(since: minutes(-100_000))
                == Baseline(bytes: 900 * MB, origin: .firstSeen), "pass \(pass)")
            #expect(try store.history(series: .app(id: "late"), since: t0).count == 21)
        }

        // The store is usable afterwards, and the migrated window baseline is the typical one.
        let store = try TrendStore(url: url)
        let relaunch = minutes(60_000)
        for m in 60_001...60_030 {
            try store.record(snapshot(at: minutes(Double(m)), apps: [app("late", bytes: 400 * MB, launch: relaunch)]))
        }
        #expect(try store.appBaseline(appID: "late", launchDate: relaunch)
            == Baseline(bytes: 400 * MB, origin: .afterLaunch))
        let late = minutes(70_000)
        for m in 90_000...90_012 {
            try store.record(snapshot(at: minutes(Double(m)), apps: [app("window", bytes: 5 * GB, launch: late)]))
        }
        #expect(try store.appBaseline(appID: "window", launchDate: late)
            == Baseline(bytes: GB, origin: .afterLaunch))

        var version: Int64 = 0
        let db = try SQLiteDatabase(path: url.path)
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        #expect(version == 1)
    }

    @Test func baselineWithNilLaunchDateUsesFirstTenSamples() throws {
        let store = try TrendStore(inMemory: true)
        try recordApp(store, launch: nil, minutes: 1...20) { m in m <= 10 ? 200 * MB : 2 * GB }
        #expect(try store.appBaseline(appID: "a", launchDate: nil) == Baseline(bytes: 200 * MB, origin: .firstSeen))
        // A dated run of the same id is a different run.
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == nil)
    }

    @Test func relaunchGetsIndependentBaseline() throws {
        let store = try TrendStore(inMemory: true)
        let relaunch = minutes(60)
        try recordApp(store, launch: t0, minutes: 1...30) { _ in 3 * GB }
        try recordApp(store, launch: relaunch, minutes: 61...90) { _ in 400 * MB }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: 3 * GB, origin: .afterLaunch))
        #expect(try store.appBaseline(appID: "a", launchDate: relaunch) == Baseline(bytes: 400 * MB, origin: .afterLaunch))
    }

    @Test func relaunchWithTooFewSamplesHasNoBaseline() throws {
        let store = try TrendStore(inMemory: true)
        let relaunch = minutes(60)
        try recordApp(store, launch: t0, minutes: 1...30) { _ in 3 * GB }
        try recordApp(store, launch: relaunch, minutes: 61...63) { _ in 400 * MB }
        #expect(try store.appBaseline(appID: "a", launchDate: relaunch) == nil)
    }

    @Test func windowServerBaselineUsesWindowAfterBoot() throws {
        let store = try TrendStore(inMemory: true)
        // Samples from before the boot must be ignored.
        for m in -10...(-1) { try store.record(snapshot(at: minutes(Double(m)), windowServer: 9 * GB)) }
        for m in 1...30 {
            let value: UInt64 = m < 5 ? 100 * MB : (m <= 20 ? 600 * MB : 3 * GB)
            try store.record(snapshot(at: minutes(Double(m)), windowServer: value))
        }
        #expect(try store.windowServerBaseline(since: t0) == Baseline(bytes: 600 * MB, origin: .afterLaunch))
    }

    @Test func windowServerBaselineFallsBackToFirstTen() throws {
        let store = try TrendStore(inMemory: true)
        for m in 100...130 {
            try store.record(snapshot(
                at: minutes(Double(m)), windowServer: m < 110 ? 700 * MB : 4 * GB))
        }
        #expect(try store.windowServerBaseline(since: t0) == Baseline(bytes: 700 * MB, origin: .firstSeen))
    }

    @Test func windowServerBaselineNilWithFewerThanFive() throws {
        let store = try TrendStore(inMemory: true)
        for m in 6...9 { try store.record(snapshot(at: minutes(Double(m)), windowServer: GB)) }
        #expect(try store.windowServerBaseline(since: t0) == nil)
        // A later boot sees none of the earlier samples.
        for m in 10...20 { try store.record(snapshot(at: minutes(Double(m)), windowServer: GB)) }
        #expect(try store.windowServerBaseline(since: minutes(19)) == nil)
    }

    @Test func pruneRemovesOldRowsButKeepsPersistedBaselines() throws {
        let store = try TrendStore(inMemory: true)
        // The app and WindowServer run for a day; baselines persist once the 20 minute window ends.
        for m in stride(from: 1, through: 24 * 60, by: 1) {
            try store.record(snapshot(
                at: minutes(Double(m)), windowServer: m <= 20 ? 500 * MB : 3 * GB,
                apps: [app("a", bytes: m <= 20 ? GB : 5 * GB)]))
        }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: GB, origin: .afterLaunch))
        #expect(try store.windowServerBaseline(since: t0) == Baseline(bytes: 500 * MB, origin: .afterLaunch))

        try store.prune(olderThan: minutes(12 * 60))
        let remaining = try store.history(series: .app(id: "a"), since: t0)
        #expect(remaining.first?.timestamp == minutes(12 * 60))
        #expect(try store.history(series: .systemUsed, since: t0).count == remaining.count)
        // The early samples are gone, the baselines are not.
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: GB, origin: .afterLaunch))
        #expect(try store.windowServerBaseline(since: t0) == Baseline(bytes: 500 * MB, origin: .afterLaunch))
    }

    @Test func pruneDropsBaselinesOfRunsWithNoRecentSamples() throws {
        let store = try TrendStore(inMemory: true)
        try recordApp(store, launch: t0, minutes: 1...30) { _ in GB }
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: GB, origin: .afterLaunch))
        try store.prune(olderThan: minutes(60))
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == nil)
    }

    @Test func fileBackedStoreSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-saver-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/trends.sqlite")

        do {
            let store = try TrendStore(url: url)
            for m in 1...25 {
                try store.record(snapshot(
                    at: minutes(Double(m)), windowServer: 800 * MB,
                    apps: [app("a", bytes: 2 * GB)]))
            }
        }

        let reopened = try TrendStore(url: url)
        #expect(try reopened.history(series: .app(id: "a"), since: t0).count == 25)
        #expect(try reopened.appBaseline(appID: "a", launchDate: t0) == Baseline(bytes: 2 * GB, origin: .afterLaunch))
        #expect(try reopened.windowServerBaseline(since: t0) == Baseline(bytes: 800 * MB, origin: .afterLaunch))
    }
}
