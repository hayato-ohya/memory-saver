import Foundation
import MemorySaverCore

/// SQLite-backed history of system, WindowServer and per-app memory.
///
/// Samples are keyed by (series, run, timestamp). `run` is the app's launch date, so a relaunched
/// app starts a fresh baseline. Series without a run (system, WindowServer, apps with no launch
/// date) use `noRun`.
public final class TrendStore: TrendStoring, @unchecked Sendable {
    private let database: SQLiteDatabase
    private let lock = NSLock()

    private static let noRun: Double = -1
    private static let systemSeries = "system"
    private static let windowServerSeries = "windowserver"
    private static let settleStart: TimeInterval = 5 * 60
    private static let settleEnd: TimeInterval = 20 * 60
    private static let minimumSamples = 5
    private static let fallbackSamples = 10
    /// Boot time derived from the system clock can shift by a little between reads.
    private static let bootTimeTolerance: TimeInterval = 30

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: url.path)
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try createSchema()
    }

    /// A private in-memory database, for tests.
    public init(inMemory: Bool = true) throws {
        database = try SQLiteDatabase(path: ":memory:")
        try createSchema()
    }

    private static let schemaVersion: Int64 = 1

    private func createSchema() throws {
        try database.inTransaction {
            // WITHOUT ROWID makes the primary key the clustered index, which is exactly what the
            // baseline queries (one run, ordered by time) read.
            try database.execute("""
                CREATE TABLE IF NOT EXISTS samples (
                    series TEXT NOT NULL,
                    run REAL NOT NULL,
                    ts REAL NOT NULL,
                    bytes INTEGER NOT NULL,
                    PRIMARY KEY (series, run, ts)
                ) WITHOUT ROWID
                """)
            // History for an app across all of its runs, and pruning by time.
            try database.execute("CREATE INDEX IF NOT EXISTS samples_series_ts ON samples (series, ts)")
            // origin is NULL only for rows written before schema version 1 (see migrate).
            try database.execute("""
                CREATE TABLE IF NOT EXISTS baselines (
                    series TEXT NOT NULL,
                    run REAL NOT NULL,
                    bytes INTEGER NOT NULL,
                    origin TEXT,
                    PRIMARY KEY (series, run)
                ) WITHOUT ROWID
                """)
            try migrate()
        }
    }

    /// Version 0 is a database created before baselines had an origin.
    private func migrate() throws {
        var version: Int64 = 0
        try database.query("PRAGMA user_version") { version = $0.int(0) }
        guard version < Self.schemaVersion else { return }

        var hasOrigin = false
        try database.query("PRAGMA table_info(baselines)") { row in
            if row.text(1) == "origin" { hasOrigin = true }
        }
        if !hasOrigin { try database.execute("ALTER TABLE baselines ADD COLUMN origin TEXT") }

        // The most recent after-launch baseline per series. Pruning never touches it.
        try database.execute("""
            CREATE TABLE IF NOT EXISTS typical_baselines (
                series TEXT NOT NULL PRIMARY KEY,
                run REAL NOT NULL,
                bytes INTEGER NOT NULL
            ) WITHOUT ROWID
            """)

        // Old rows were first-seen values unless the run's samples show the 5-20 minute window
        // was used (the old code only stored a window value once the window had closed).
        var legacy: [(series: String, run: Double, bytes: UInt64)] = []
        try database.query("SELECT series, run, bytes FROM baselines WHERE origin IS NULL") {
            legacy.append(($0.text(0), $0.double(1), Self.unsigned($0.int(2))))
        }
        for row in legacy {
            let sampleRun = row.series == Self.windowServerSeries ? Self.noRun : row.run
            var windowed = false
            if row.run != Self.noRun {
                try database.query(
                    "SELECT 1 FROM samples WHERE series = ? AND run = ? AND ts BETWEEN ? AND ? LIMIT 1",
                    [.text(row.series), .double(sampleRun), .double(row.run + Self.settleStart),
                     .double(row.run + Self.settleEnd)]
                ) { _ in windowed = true }
            }
            let origin: Baseline.Origin = windowed ? .afterLaunch : .firstSeen
            try database.execute(
                "UPDATE baselines SET origin = ? WHERE series = ? AND run = ?",
                [.text(origin.rawValue), .text(row.series), .double(row.run)])
            if windowed { try setTypical(series: row.series, run: row.run, bytes: row.bytes) }
        }
        try database.execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    // MARK: TrendStoring

    public func record(_ snapshot: MemorySnapshot) throws {
        let ts = snapshot.timestamp.timeIntervalSince1970
        try locked {
            try database.inTransaction {
                try insert(Self.systemSeries, run: Self.noRun, ts: ts, bytes: snapshot.system.usedBytes)
                if let windowServer = snapshot.windowServerBytes {
                    try insert(Self.windowServerSeries, run: Self.noRun, ts: ts, bytes: windowServer)
                }
                for app in snapshot.apps {
                    let run = app.launchDate?.timeIntervalSince1970 ?? Self.noRun
                    try insert(Self.appSeries(app.id), run: run, ts: ts, bytes: app.footprintBytes)
                }
            }
            // Settle baselines as soon as they can be, not when first asked: the advisor only
            // asks about big apps, and a run that was never settled cannot become a typical baseline.
            for app in snapshot.apps {
                let run = app.launchDate?.timeIntervalSince1970 ?? Self.noRun
                let series = Self.appSeries(app.id)
                if try storedBaseline(series: series, run: run) == nil {
                    _ = try computeBaseline(
                        series: series, run: run, anchor: app.launchDate?.timeIntervalSince1970,
                        sampleStart: -.greatestFiniteMagnitude, sampleRun: run, typicalBefore: .infinity)
                }
            }
        }
    }

    public func appBaseline(appID: String, launchDate: Date?) throws -> Baseline? {
        let run = launchDate?.timeIntervalSince1970 ?? Self.noRun
        return try locked {
            let series = Self.appSeries(appID)
            if let stored = try storedBaseline(series: series, run: run) { return stored }
            return try computeBaseline(
                series: series, run: run, anchor: launchDate?.timeIntervalSince1970,
                sampleStart: -.greatestFiniteMagnitude, sampleRun: run, typicalBefore: .infinity)
        }
    }

    public func windowServerBaseline(since windowServerStart: Date) throws -> Baseline? {
        let boot = windowServerStart.timeIntervalSince1970
        return try locked {
            var stored: Baseline?
            try database.query(
                """
                SELECT bytes, origin FROM baselines WHERE series = ? AND run BETWEEN ? AND ?
                ORDER BY ABS(run - ?) LIMIT 1
                """,
                [.text(Self.windowServerSeries), .double(boot - Self.bootTimeTolerance),
                 .double(boot + Self.bootTimeTolerance), .double(boot)]
            ) { stored = Self.baseline($0, bytes: 0, origin: 1) }
            if let stored { return stored }
            return try computeBaseline(
                series: Self.windowServerSeries, run: boot, anchor: boot, sampleStart: boot,
                sampleRun: Self.noRun, typicalBefore: boot - Self.bootTimeTolerance)
        }
    }

    public func history(series: SeriesKey, since: Date) throws -> [TrendPoint] {
        let name: String
        switch series {
        case .systemUsed: name = Self.systemSeries
        case .windowServer: name = Self.windowServerSeries
        case .app(let id): name = Self.appSeries(id)
        }
        return try locked {
            var points: [TrendPoint] = []
            try database.query(
                "SELECT ts, bytes FROM samples WHERE series = ? AND ts >= ? ORDER BY ts",
                [.text(name), .double(since.timeIntervalSince1970)]
            ) { row in
                points.append(TrendPoint(
                    timestamp: Date(timeIntervalSince1970: row.double(0)),
                    bytes: Self.unsigned(row.int(1))))
            }
            return points
        }
    }

    public func prune(olderThan cutoff: Date) throws {
        let cutoff = cutoff.timeIntervalSince1970
        try locked {
            try database.inTransaction {
                try database.execute("DELETE FROM samples WHERE ts < ?", [.double(cutoff)])
                // An app run that has had no samples since the cutoff is gone.
                try database.execute("""
                    DELETE FROM baselines WHERE series != ? AND NOT EXISTS (
                        SELECT 1 FROM samples s
                        WHERE s.series = baselines.series AND s.run = baselines.run AND s.ts >= ?)
                    """, [.text(Self.windowServerSeries), .double(cutoff)])
                // WindowServer baselines are per boot: drop them once WindowServer has no
                // recent samples, and drop old boots superseded by a later one.
                try database.execute("""
                    DELETE FROM baselines WHERE series = ? AND (
                        NOT EXISTS (SELECT 1 FROM samples WHERE series = ? AND ts >= ?)
                        OR (run < ? AND run < (SELECT MAX(run) FROM baselines WHERE series = ?)))
                    """, [.text(Self.windowServerSeries), .text(Self.windowServerSeries),
                          .double(cutoff), .double(cutoff), .text(Self.windowServerSeries)])
            }
        }
    }

    // MARK: Internals

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func appSeries(_ id: String) -> String { "app:" + id }

    private static func signed(_ bytes: UInt64) -> Int64 { Int64(clamping: bytes) }
    private static func unsigned(_ value: Int64) -> UInt64 { UInt64(max(0, value)) }

    private func insert(_ series: String, run: Double, ts: Double, bytes: UInt64) throws {
        try database.execute(
            "INSERT OR REPLACE INTO samples (series, run, ts, bytes) VALUES (?, ?, ?, ?)",
            [.text(series), .double(run), .double(ts), .int(Self.signed(bytes))])
    }

    private static func baseline(_ row: SQLiteDatabase.Row, bytes: Int32, origin: Int32) -> Baseline {
        Baseline(
            bytes: unsigned(row.int(bytes)),
            origin: Baseline.Origin(rawValue: row.text(origin)) ?? .firstSeen)
    }

    private func storedBaseline(series: String, run: Double) throws -> Baseline? {
        var stored: Baseline?
        try database.query(
            "SELECT bytes, origin FROM baselines WHERE series = ? AND run = ?",
            [.text(series), .double(run)]
        ) { stored = Self.baseline($0, bytes: 0, origin: 1) }
        return stored
    }

    private func setTypical(series: String, run: Double, bytes: UInt64) throws {
        try database.execute("""
            INSERT INTO typical_baselines (series, run, bytes) VALUES (?, ?, ?)
            ON CONFLICT (series) DO UPDATE SET run = excluded.run, bytes = excluded.bytes
            WHERE excluded.run > typical_baselines.run
            """, [.text(series), .double(run), .int(Self.signed(bytes))])
    }

    /// Computes the baseline from samples once it is settled, persists it and returns it.
    /// Returns nil while it could still change. Caller holds the lock.
    ///
    /// - run: the key the baseline is stored under (launch or boot time, or `noRun`).
    /// - anchor: launch or boot time, which the 5-20 minute window is measured from.
    ///   nil means no anchor, so only the first-10-samples rule applies.
    /// - sampleStart: ignore samples before this time (WindowServer samples before boot).
    /// - sampleRun: the `run` value the samples are stored under.
    /// - typicalBefore: a typical baseline is only used if it comes from a run before this one.
    private func computeBaseline(
        series: String, run: Double, anchor: Double?, sampleStart: Double, sampleRun: Double,
        typicalBefore: Double
    ) throws -> Baseline? {
        var samples: [(ts: Double, bytes: UInt64)] = []
        try database.query(
            "SELECT ts, bytes FROM samples WHERE series = ? AND run = ? AND ts >= ? ORDER BY ts",
            [.text(series), .double(sampleRun), .double(sampleStart)]
        ) { samples.append(($0.double(0), Self.unsigned($0.int(1)))) }
        guard let last = samples.last else { return nil }

        var windowed: [UInt64] = []
        // The window has closed once a sample exists past its end.
        var windowClosed = false
        if let anchor {
            windowed = samples
                .filter { $0.ts >= anchor + Self.settleStart && $0.ts <= anchor + Self.settleEnd }
                .map(\.bytes)
            windowClosed = last.ts >= anchor + Self.settleEnd
        }

        let baseline: Baseline
        if !windowed.isEmpty {
            guard windowClosed else { return nil }
            baseline = Baseline(bytes: Self.median(windowed), origin: .afterLaunch)
        } else {
            // Without an anchor there is no window to wait for. With one, wait until it is over so
            // that start-up samples are never taken for a baseline.
            guard samples.count >= Self.fallbackSamples, anchor == nil || windowClosed else { return nil }
            var typical: UInt64?
            try database.query(
                "SELECT bytes FROM typical_baselines WHERE series = ? AND run < ?",
                [.text(series), .double(typicalBefore)]
            ) { typical = Self.unsigned($0.int(0)) }
            if let typical {
                baseline = Baseline(bytes: typical, origin: .afterLaunch)
            } else {
                baseline = Baseline(
                    bytes: Self.median(samples.prefix(Self.fallbackSamples).map(\.bytes)),
                    origin: .firstSeen)
            }
        }

        try database.inTransaction {
            try database.execute(
                "INSERT OR REPLACE INTO baselines (series, run, bytes, origin) VALUES (?, ?, ?, ?)",
                [.text(series), .double(run), .int(Self.signed(baseline.bytes)),
                 .text(baseline.origin.rawValue)])
            // Only a measurement of this run counts as typical, not a substituted one.
            if !windowed.isEmpty { try setTypical(series: series, run: run, bytes: baseline.bytes) }
        }
        return baseline
    }

    private static func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        let low = sorted[middle - 1]
        return low + (sorted[middle] - low) / 2
    }
}
