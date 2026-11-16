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

        let db = try SQLiteDatabase(path: url.path)
        #expect(try value(db, "PRAGMA user_version") == 2)
        #expect(try value(db, "PRAGMA auto_vacuum") == 2)
        #expect(try tableNames(db) == ["baselines", "runs", "samples", "series", "typical_baselines"])
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

    // MARK: Schema version 2

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-saver-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func value(_ db: SQLiteDatabase, _ sql: String) throws -> Int64 {
        var result: Int64 = 0
        try db.query(sql) { result = $0.int(0) }
        return result
    }

    private func tableNames(_ db: SQLiteDatabase) throws -> [String] {
        var names: [String] = []
        try db.query("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name") {
            names.append($0.text(0))
        }
        return names
    }

    private struct BaselineRow: Hashable {
        var series: String
        var run: Double
        var bytes: Int64
        var origin: String?
    }

    /// Every stored and typical baseline, keyed by series name, from a version 1 or 2 file.
    private func baselineRows(_ db: SQLiteDatabase) throws -> (stored: Set<BaselineRow>, typical: Set<BaselineRow>) {
        let v2 = try tableNames(db).contains("series")
        var stored = Set<BaselineRow>()
        try db.query(v2
            ? "SELECT n.name, b.run, b.bytes, b.origin, b.origin IS NULL FROM baselines b JOIN series n ON n.id = b.series_id"
            : "SELECT series, run, bytes, origin, origin IS NULL FROM baselines"
        ) { stored.insert(BaselineRow(series: $0.text(0), run: $0.double(1), bytes: $0.int(2),
                                      origin: $0.int(4) == 1 ? nil : $0.text(3))) }
        var typical = Set<BaselineRow>()
        try db.query(v2
            ? "SELECT n.name, t.run, t.bytes FROM typical_baselines t JOIN series n ON n.id = t.series_id"
            : "SELECT series, run, bytes FROM typical_baselines"
        ) { typical.insert(BaselineRow(series: $0.text(0), run: $0.double(1), bytes: $0.int(2))) }
        return (stored, typical)
    }

    @Test func normalisedStoreKeepsExactTimesAndBaselines() throws {
        let store = try TrendStore(inMemory: true)
        // Launch and sample times with fractions of a second, as the real clock gives them.
        let launch = t0.addingTimeInterval(0.6)
        var expected: [TrendPoint] = []
        for m in 1...30 {
            // Minute 5 lands 0.2 s after the window opens (launch + 5 min), so it is in the
            // window; truncating it to a whole second would move it out.
            let at = t0.addingTimeInterval(Double(m) * 60 + (m == 5 ? 0.8 : 0.25))
            let bytes: UInt64 = switch m {
            case ..<5: 300 * MB
            case 5: 9 * GB
            case 6...13: GB
            case 14...20: 2 * GB
            default: 4 * GB
            }
            try store.record(snapshot(
                at: at, windowServer: 500 * MB,
                apps: [app("a", bytes: bytes, launch: launch), app("b", bytes: 2 * GB, launch: nil)]))
            expected.append(TrendPoint(timestamp: at, bytes: bytes))
        }
        #expect(try store.history(series: .app(id: "a"), since: t0) == expected)
        #expect(try store.history(series: .app(id: "a"), since: expected[10].timestamp) == Array(expected[10...]))
        // Minutes 5...20: eight of GB, seven of 2 GB and 9 GB. Without minute 5 it would be GB.
        #expect(try store.appBaseline(appID: "a", launchDate: launch) == Baseline(bytes: 3 * GB / 2, origin: .afterLaunch))
        #expect(try store.appBaseline(appID: "a", launchDate: t0) == nil)
        #expect(try store.appBaseline(appID: "b", launchDate: nil) == Baseline(bytes: 2 * GB, origin: .firstSeen))
        #expect(try store.windowServerBaseline(since: t0) == Baseline(bytes: 500 * MB, origin: .afterLaunch))
        #expect(try store.history(series: .systemUsed, since: t0).count == 30)
    }

    @Test func pruneThinsSamplesOlderThanADayToPeakPerBucket() throws {
        let store = try TrendStore(inMemory: true)
        let total = 3 * 24 * 60
        func bytes(_ m: Int) -> UInt64 { UInt64(1000 + (m * 7919) % 997) * MB }
        // "b" runs for three minutes only, so its baseline never settles. Such a run keeps
        // every sample: they may still decide its baseline.
        for m in 0...total {
            try store.record(snapshot(
                at: minutes(Double(m)), used: bytes(m) + GB,
                apps: [app("a", bytes: bytes(m))] + ((1...3).contains(m) ? [app("b", bytes: GB)] : [])))
        }
        let baseline = try store.appBaseline(appID: "a", launchDate: t0)
        #expect(baseline != nil)
        let before = try store.history(series: .app(id: "a"), since: .distantPast)

        let bucket = Int64(TrendStore.downsampleBucket)
        let newest = minutes(Double(total)).timeIntervalSince1970
        let limit = Double(Int64((newest - TrendStore.fullResolutionPeriod) / Double(bucket)) * bucket)
        var peaks: [Int64: TrendPoint] = [:]
        for point in before where point.timestamp.timeIntervalSince1970 < limit {
            let key = Int64(point.timestamp.timeIntervalSince1970) / bucket
            if let kept = peaks[key], kept.bytes >= point.bytes { continue }
            peaks[key] = point
        }
        let expected = peaks.values.sorted { $0.timestamp < $1.timestamp }
            + before.filter { $0.timestamp.timeIntervalSince1970 >= limit }

        for pass in 1...2 {
            try store.prune(olderThan: minutes(-1))
            let after = try store.history(series: .app(id: "a"), since: .distantPast)
            #expect(after == expected, "pass \(pass)")
            #expect(after.filter { $0.timestamp.timeIntervalSince1970 >= limit }.count
                == before.filter { $0.timestamp.timeIntervalSince1970 >= limit }.count)
            let system = try store.history(series: .systemUsed, since: .distantPast)
            #expect(system.map(\.timestamp) == expected.map(\.timestamp), "pass \(pass)")
            #expect(try store.history(series: .app(id: "b"), since: .distantPast).count == 3)
            #expect(try store.appBaseline(appID: "a", launchDate: t0) == baseline)
        }
        // About two days at one per 15 minutes, plus the last day in full.
        #expect(expected.count < 2 * 24 * 4 + 24 * 60 + 20)
    }

    @Test func pruneRemovesOrphanedSeriesAndRunsButKeepsBaselines() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let store = try TrendStore(url: url)
        // "typical" settles after launch (so it becomes typical) and then quits.
        // "orphan" never settles and quits. "live" keeps running, as do WindowServer and system.
        try recordApp(store, id: "typical", minutes: 1...30) { _ in 600 * MB }
        try recordApp(store, id: "orphan", launch: nil, minutes: 1...5) { _ in GB }
        for m in 1...3000 {
            try store.record(snapshot(
                at: minutes(Double(m)), windowServer: m <= 20 ? 500 * MB : 3 * GB,
                apps: [app("live", bytes: m <= 20 ? GB : 5 * GB)]))
        }
        #expect(try store.appBaseline(appID: "live", launchDate: t0) == Baseline(bytes: GB, origin: .afterLaunch))
        #expect(try store.windowServerBaseline(since: t0) == Baseline(bytes: 500 * MB, origin: .afterLaunch))

        try store.prune(olderThan: minutes(2000))
        let db = try SQLiteDatabase(path: url.path)
        var names: [String] = []
        try db.query("SELECT name FROM series ORDER BY name") { names.append($0.text(0)) }
        #expect(names == ["app:live", "app:typical", "system", "windowserver"])
        #expect(try value(db, "SELECT COUNT(*) FROM runs") == 3)
        #expect(try value(db, "SELECT MIN(ts) FROM samples") == Int64(minutes(2000).timeIntervalSince1970))
        // Settled baselines of running things survive; the typical one survives its run.
        #expect(try store.appBaseline(appID: "live", launchDate: t0) == Baseline(bytes: GB, origin: .afterLaunch))
        #expect(try store.windowServerBaseline(since: t0) == Baseline(bytes: 500 * MB, origin: .afterLaunch))
        #expect(try store.appBaseline(appID: "typical", launchDate: t0) == nil)
        #expect(try store.history(series: .app(id: "orphan"), since: .distantPast).isEmpty)
        let late = minutes(5000)
        try recordApp(store, id: "typical", launch: late, minutes: 6000...6012) { _ in 3 * GB }
        #expect(try store.appBaseline(appID: "typical", launchDate: late)
            == Baseline(bytes: 600 * MB, origin: .afterLaunch))
    }

    @Test func fileShrinksAfterPrune() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let wal = URL(fileURLWithPath: url.path + "-wal")
        func size(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        }
        let store = try TrendStore(url: url)
        let apps = (0..<5).map { "app\($0)" }
        for m in 0...(2 * 24 * 60) {
            try store.record(snapshot(
                at: minutes(Double(m)), windowServer: GB,
                apps: apps.map { app($0, bytes: GB + UInt64(m)) }))
        }
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let pagesBefore = try value(db, "PRAGMA page_count")
        let sizeBefore = size(url)

        try store.prune(olderThan: minutes(36 * 60))
        let pagesAfter = try value(db, "PRAGMA page_count")
        #expect(pagesAfter < pagesBefore / 2, "\(pagesBefore) -> \(pagesAfter) pages")
        #expect(size(url) < sizeBefore / 2, "\(sizeBefore) -> \(size(url)) bytes")
        #expect(size(wal) == 0)
        #expect(try value(db, "PRAGMA freelist_count") == 0)
    }

    // The exact statements of schema version 1.
    private func version1Database(at url: URL) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS samples (
                series TEXT NOT NULL,
                run REAL NOT NULL,
                ts REAL NOT NULL,
                bytes INTEGER NOT NULL,
                PRIMARY KEY (series, run, ts)
            ) WITHOUT ROWID
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS samples_series_ts ON samples (series, ts)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS baselines (
                series TEXT NOT NULL,
                run REAL NOT NULL,
                bytes INTEGER NOT NULL,
                origin TEXT,
                PRIMARY KEY (series, run)
            ) WITHOUT ROWID
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS typical_baselines (
                series TEXT NOT NULL PRIMARY KEY,
                run REAL NOT NULL,
                bytes INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
        try db.execute("PRAGMA user_version = 1")

        let launch = t0.timeIntervalSince1970 + 0.6
        try db.inTransaction {
            for m in 1...600 {
                let ts = minutes(Double(m)).timeIntervalSince1970 + 0.25
                for (series, run, bytes) in [
                    ("system", -1.0, 8 * GB), ("windowserver", -1.0, 500 * MB),
                    ("app:com.example.long.bundle.identifier", launch, m <= 20 ? GB : 3 * GB),
                ] {
                    try db.execute("INSERT INTO samples VALUES (?, ?, ?, ?)",
                                   [.text(series), .double(run), .double(ts), .int(Int64(bytes))])
                }
            }
            // Two samples less than a second apart: both are kept.
            for ts in [t0.timeIntervalSince1970 + 0.1, t0.timeIntervalSince1970 + 0.9] {
                try db.execute("INSERT INTO samples VALUES ('app:close', -1, ?, ?)", [.double(ts), .int(Int64(GB))])
            }
            try db.execute("INSERT INTO baselines VALUES ('app:com.example.long.bundle.identifier', ?, ?, 'afterLaunch')",
                           [.double(launch), .int(Int64(GB))])
            try db.execute("INSERT INTO baselines VALUES ('windowserver', ?, ?, 'afterLaunch')",
                           [.double(t0.timeIntervalSince1970 + 0.123456), .int(Int64(500 * MB))])
            try db.execute("INSERT INTO baselines VALUES ('app:gone', 1234.5678, 42, 'firstSeen')")
            try db.execute("INSERT INTO typical_baselines VALUES ('app:com.example.long.bundle.identifier', ?, ?)",
                           [.double(launch), .int(Int64(GB))])
            try db.execute("INSERT INTO typical_baselines VALUES ('app:quit', 99.25, 7)")
        }
    }

    @Test func migratesVersion1ToVersion2() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        try version1Database(at: url)
        let original = try SQLiteDatabase(path: url.path)
        let rowsBefore = try baselineRows(original)
        var historyBefore: [Double] = []
        try original.query("SELECT ts FROM samples WHERE series = 'system' ORDER BY ts") { historyBefore.append($0.double(0)) }
        try original.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let pagesBefore = try value(original, "PRAGMA page_count")
        #expect(try value(original, "PRAGMA auto_vacuum") == 0)

        let launch = t0.addingTimeInterval(0.6)
        for pass in 1...2 {
            let store = try TrendStore(url: url)
            let db = try SQLiteDatabase(path: url.path)
            #expect(try value(db, "PRAGMA user_version") == 2)
            #expect(try value(db, "PRAGMA auto_vacuum") == 2)
            #expect(try tableNames(db) == ["baselines", "runs", "samples", "series", "typical_baselines"])
            #expect(try value(db, "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'samples_series_ts'") == 0)
            #expect(try value(db, "SELECT COUNT(*) FROM samples") == 3 * 600 + 2)
            #expect(try value(db, "PRAGMA page_count") < pagesBefore, "pass \(pass)")
            let rowsAfter = try baselineRows(db)
            #expect(rowsAfter.stored == rowsBefore.stored, "pass \(pass)")
            #expect(rowsAfter.typical == rowsBefore.typical, "pass \(pass)")
            #expect(try store.history(series: .systemUsed, since: .distantPast).map(\.timestamp.timeIntervalSince1970)
                == historyBefore)
            #expect(try store.history(series: .app(id: "close"), since: .distantPast).count == 2)
            #expect(try store.appBaseline(appID: "com.example.long.bundle.identifier", launchDate: launch)
                == Baseline(bytes: GB, origin: .afterLaunch))
            #expect(try store.windowServerBaseline(since: t0) == Baseline(bytes: 500 * MB, origin: .afterLaunch))
        }

        // The migrated typical baseline still serves a late relaunch.
        let store = try TrendStore(url: url)
        let late = minutes(10_000)
        for m in 20_000...20_012 {
            try store.record(snapshot(
                at: minutes(Double(m)), apps: [app("com.example.long.bundle.identifier", bytes: 5 * GB, launch: late)]))
        }
        #expect(try store.appBaseline(appID: "com.example.long.bundle.identifier", launchDate: late)
            == Baseline(bytes: GB, origin: .afterLaunch))
    }

    @Test func failedMigrationLeavesVersion1DataIntact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        try version1Database(at: url)
        // A table in the way of the new schema makes the migration fail halfway.
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("CREATE TABLE runs (x)")
        let rowsBefore = try baselineRows(db)

        #expect(throws: (any Error).self) { try TrendStore(url: url) }
        #expect(try value(db, "PRAGMA user_version") == 1)
        #expect(try tableNames(db) == ["baselines", "runs", "samples", "typical_baselines"])
        #expect(try value(db, "SELECT COUNT(*) FROM samples") == 3 * 600 + 2)
        #expect(try value(db, "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'samples_series_ts'") == 1)
        let rowsAfter = try baselineRows(db)
        #expect(rowsAfter.stored == rowsBefore.stored)
        #expect(rowsAfter.typical == rowsBefore.typical)
    }
}
