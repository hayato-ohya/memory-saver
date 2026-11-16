import Foundation
import MemorySaverCore

/// SQLite-backed history of system, WindowServer and per-app memory.
///
/// Samples are keyed by (series, run, timestamp). `run` is the app's launch date, so a relaunched
/// app starts a fresh baseline. Series without a run (system, WindowServer, apps with no launch
/// date) use `noRun`. Series names and (series, run) pairs are stored once, in `series` and
/// `runs`; `samples` refers to a run by its integer id.
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
    /// Samples newer than this (measured back from the newest sample) are all kept.
    static let fullResolutionPeriod: TimeInterval = 24 * 3600
    /// Older samples are thinned to the largest one per run in each bucket of this length.
    static let downsampleBucket: TimeInterval = 15 * 60

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: url.path)
        // Must be set before the first table is created. Not set on an existing file: even
        // setting the current value rewrites the header.
        var isNew = false
        try database.query("SELECT COUNT(*) FROM sqlite_schema") { isNew = $0.int(0) == 0 }
        if isNew { try database.execute("PRAGMA auto_vacuum = INCREMENTAL") }
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        // Each sample touches one page per run, about 30 pages a minute. At the default of 1000
        // pages the WAL file would regrow to 4 MB, more than the database itself.
        try database.execute("PRAGMA wal_autocheckpoint = 128")
        try createSchema()
        try enableIncrementalVacuum()
    }

    /// A private in-memory database, for tests.
    public init(inMemory: Bool = true) throws {
        database = try SQLiteDatabase(path: ":memory:")
        try createSchema()
    }

    private static let schemaVersion: Int64 = 2

    private func createSchema() throws {
        var version: Int64 = 0
        try database.query("PRAGMA user_version") { version = $0.int(0) }
        guard version < Self.schemaVersion else { return }

        try database.inTransaction {
            var hasLegacySamples = false
            try database.query("SELECT 1 FROM pragma_table_info('samples') WHERE name = 'series'") { _ in
                hasLegacySamples = true
            }
            if hasLegacySamples {
                if version < 1 { try migrateToVersion1() }
                try migrateToVersion2()
            } else {
                try createTables()
            }
            try database.execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    private func createTables() throws {
        try database.execute("""
            CREATE TABLE series (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE
            )
            """)
        // last_ts is the newest sample ever recorded for the run. Pruning decides whether a run
        // is still alive from it, so thinning old samples cannot change that decision.
        try database.execute("""
            CREATE TABLE runs (
                id INTEGER PRIMARY KEY,
                series_id INTEGER NOT NULL,
                run REAL NOT NULL,
                last_ts REAL NOT NULL,
                UNIQUE (series_id, run)
            )
            """)
        // WITHOUT ROWID makes the primary key the clustered index, which is exactly what the
        // baseline queries (one run, ordered by time) read. ts stays REAL: launch dates have
        // fractions of a second, and the 5-20 minute window is compared against them.
        try database.execute("""
            CREATE TABLE samples (
                run_id INTEGER NOT NULL,
                ts REAL NOT NULL,
                bytes INTEGER NOT NULL,
                PRIMARY KEY (run_id, ts)
            ) WITHOUT ROWID
            """)
        // run is the exact launch or boot time; WindowServer baselines are not keyed by the
        // run their samples are stored under, so this table does not refer to `runs`.
        // origin is NULL only for rows written before schema version 1.
        try database.execute("""
            CREATE TABLE baselines (
                series_id INTEGER NOT NULL,
                run REAL NOT NULL,
                bytes INTEGER NOT NULL,
                origin TEXT,
                PRIMARY KEY (series_id, run)
            ) WITHOUT ROWID
            """)
        // The most recent after-launch baseline per series. Pruning never touches it.
        try database.execute("""
            CREATE TABLE typical_baselines (
                series_id INTEGER NOT NULL PRIMARY KEY,
                run REAL NOT NULL,
                bytes INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
    }

    /// Version 0 is a database created before baselines had an origin. Works on the version 1
    /// layout (series names in every row); `migrateToVersion2` runs right after it.
    private func migrateToVersion1() throws {
        var hasOrigin = false
        try database.query("PRAGMA table_info(baselines)") { row in
            if row.text(1) == "origin" { hasOrigin = true }
        }
        if !hasOrigin { try database.execute("ALTER TABLE baselines ADD COLUMN origin TEXT") }

        try database.execute("""
            CREATE TABLE IF NOT EXISTS typical_baselines (
                series TEXT NOT NULL PRIMARY KEY,
                run REAL NOT NULL,
                bytes INTEGER NOT NULL
            ) WITHOUT ROWID
            """)

        // Old rows were first-seen values unless the run's samples show the 5-20 minute window
        // was used (the old code only stored a window value once the window had closed).
        var legacy: [(series: String, run: Double, bytes: Int64)] = []
        try database.query("SELECT series, run, bytes FROM baselines WHERE origin IS NULL") {
            legacy.append(($0.text(0), $0.double(1), $0.int(2)))
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
            if windowed {
                try database.execute("""
                    INSERT INTO typical_baselines (series, run, bytes) VALUES (?, ?, ?)
                    ON CONFLICT (series) DO UPDATE SET run = excluded.run, bytes = excluded.bytes
                    WHERE excluded.run > typical_baselines.run
                    """, [.text(row.series), .double(row.run), .int(row.bytes)])
            }
        }
    }

    /// Version 1 repeated the series name in every sample and in an index. Copies everything
    /// into the version 2 tables unchanged (timestamps and run values keep full precision).
    private func migrateToVersion2() throws {
        try database.execute("DROP INDEX IF EXISTS samples_series_ts")
        try database.execute("ALTER TABLE samples RENAME TO samples_v1")
        try database.execute("ALTER TABLE baselines RENAME TO baselines_v1")
        try database.execute("ALTER TABLE typical_baselines RENAME TO typical_baselines_v1")
        try createTables()
        try database.execute("""
            INSERT INTO series (name)
            SELECT series FROM samples_v1 UNION SELECT series FROM baselines_v1
            UNION SELECT series FROM typical_baselines_v1
            """)
        try database.execute("""
            INSERT INTO runs (series_id, run, last_ts)
            SELECT n.id, s.run, MAX(s.ts) FROM samples_v1 s JOIN series n ON n.name = s.series
            GROUP BY n.id, s.run
            """)
        try database.execute("""
            INSERT INTO samples (run_id, ts, bytes)
            SELECT r.id, s.ts, s.bytes FROM samples_v1 s
            JOIN series n ON n.name = s.series JOIN runs r ON r.series_id = n.id AND r.run = s.run
            """)
        try database.execute("""
            INSERT INTO baselines (series_id, run, bytes, origin)
            SELECT n.id, b.run, b.bytes, b.origin FROM baselines_v1 b JOIN series n ON n.name = b.series
            """)
        try database.execute("""
            INSERT INTO typical_baselines (series_id, run, bytes)
            SELECT n.id, t.run, t.bytes FROM typical_baselines_v1 t JOIN series n ON n.name = t.series
            """)
        try database.execute("DROP TABLE samples_v1")
        try database.execute("DROP TABLE baselines_v1")
        try database.execute("DROP TABLE typical_baselines_v1")
    }

    /// A file created before version 2 has no auto-vacuum, so deleted rows never gave space
    /// back. Switching needs a full VACUUM; it is retried at the next launch if it fails, and
    /// a failure does not stop the store from working.
    private func enableIncrementalVacuum() throws {
        var mode: Int64 = 0
        try database.query("PRAGMA auto_vacuum") { mode = $0.int(0) }
        guard mode != 2 else { return }
        try database.execute("PRAGMA auto_vacuum = INCREMENTAL")
        try? database.execute("VACUUM")
        try? database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
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
                SELECT b.bytes, b.origin FROM baselines b JOIN series n ON n.id = b.series_id
                WHERE n.name = ? AND b.run BETWEEN ? AND ?
                ORDER BY ABS(b.run - ?) LIMIT 1
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
            // Range-scans each run of the series, then merges them by time.
            try database.query(
                """
                SELECT s.ts, s.bytes FROM series n
                JOIN runs r ON r.series_id = n.id JOIN samples s ON s.run_id = r.id
                WHERE n.name = ? AND s.ts >= ? ORDER BY s.ts
                """,
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
                // Per run, so each delete is a range of the primary key.
                try database.execute(
                    "DELETE FROM samples WHERE run_id IN (SELECT id FROM runs) AND ts < ?",
                    [.double(cutoff)])
                // An app run that has had no samples since the cutoff is gone.
                try database.execute("""
                    DELETE FROM baselines
                    WHERE series_id NOT IN (SELECT id FROM series WHERE name = ?) AND NOT EXISTS (
                        SELECT 1 FROM runs r
                        WHERE r.series_id = baselines.series_id AND r.run = baselines.run
                            AND r.last_ts >= ?)
                    """, [.text(Self.windowServerSeries), .double(cutoff)])
                // WindowServer baselines are per boot: drop them once WindowServer has no
                // recent samples, and drop old boots superseded by a later one.
                try database.execute("""
                    DELETE FROM baselines
                    WHERE series_id = (SELECT id FROM series WHERE name = ?) AND (
                        NOT EXISTS (
                            SELECT 1 FROM runs
                            WHERE runs.series_id = baselines.series_id AND runs.last_ts >= ?)
                        OR (run < ? AND run < (
                            SELECT MAX(run) FROM baselines b WHERE b.series_id = baselines.series_id)))
                    """, [.text(Self.windowServerSeries), .double(cutoff), .double(cutoff)])
                // These runs have no samples left.
                try database.execute("DELETE FROM runs WHERE last_ts < ?", [.double(cutoff)])
                try downsample()
                try database.execute("""
                    DELETE FROM series WHERE id NOT IN (SELECT series_id FROM runs)
                        AND id NOT IN (SELECT series_id FROM baselines)
                        AND id NOT IN (SELECT series_id FROM typical_baselines)
                    """)
            }
            try database.execute("PRAGMA incremental_vacuum")
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
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
            "INSERT INTO series (name) VALUES (?) ON CONFLICT (name) DO NOTHING", [.text(series)])
        var runID: Int64 = 0
        try database.query(
            """
            INSERT INTO runs (series_id, run, last_ts) VALUES ((SELECT id FROM series WHERE name = ?), ?, ?)
            ON CONFLICT (series_id, run) DO UPDATE SET last_ts = MAX(last_ts, excluded.last_ts)
            RETURNING id
            """,
            [.text(series), .double(run), .double(ts)]
        ) { runID = $0.int(0) }
        try database.execute(
            "INSERT OR REPLACE INTO samples (run_id, ts, bytes) VALUES (?, ?, ?)",
            [.int(runID), .double(ts), .int(Self.signed(bytes))])
    }

    /// Keeps every sample from the last `fullResolutionPeriod` before the newest one. Before
    /// that, keeps one sample per run in each `downsampleBucket`: the largest (the earliest of
    /// equal ones), so peaks survive. Only whole buckets are thinned, so running it again
    /// changes nothing. App runs are thinned only once their baseline is settled, because
    /// until then their early samples may still decide it.
    private func downsample() throws {
        let bucket = Int64(Self.downsampleBucket)
        var newest: Double?
        try database.query("SELECT MAX(last_ts) FROM runs") { row in
            newest = row.isNull(0) ? nil : row.double(0)
        }
        guard let newest else { return }
        let limit = Int64((newest - Self.fullResolutionPeriod) / Double(bucket)) * bucket
        try database.execute("""
            DELETE FROM samples
            WHERE run_id IN (
                SELECT r.id FROM runs r JOIN series n ON n.id = r.series_id
                WHERE n.name IN (?, ?) OR EXISTS (
                    SELECT 1 FROM baselines b WHERE b.series_id = r.series_id AND b.run = r.run))
            AND ts < ? AND EXISTS (
                SELECT 1 FROM samples o
                WHERE o.run_id = samples.run_id
                    AND o.ts >= CAST(samples.ts AS INTEGER) / ? * ?
                    AND o.ts < CAST(samples.ts AS INTEGER) / ? * ? + ?
                    AND (o.bytes > samples.bytes OR (o.bytes = samples.bytes AND o.ts < samples.ts)))
            """,
            [.text(Self.systemSeries), .text(Self.windowServerSeries), .int(limit),
             .int(bucket), .int(bucket), .int(bucket), .int(bucket), .int(bucket)])
    }

    private static func baseline(_ row: SQLiteDatabase.Row, bytes: Int32, origin: Int32) -> Baseline {
        Baseline(
            bytes: unsigned(row.int(bytes)),
            origin: Baseline.Origin(rawValue: row.text(origin)) ?? .firstSeen)
    }

    private func storedBaseline(series: String, run: Double) throws -> Baseline? {
        var stored: Baseline?
        try database.query(
            """
            SELECT b.bytes, b.origin FROM baselines b JOIN series n ON n.id = b.series_id
            WHERE n.name = ? AND b.run = ?
            """,
            [.text(series), .double(run)]
        ) { stored = Self.baseline($0, bytes: 0, origin: 1) }
        return stored
    }

    private func setTypical(series: String, run: Double, bytes: UInt64) throws {
        try database.execute("""
            INSERT INTO typical_baselines (series_id, run, bytes)
            VALUES ((SELECT id FROM series WHERE name = ?), ?, ?)
            ON CONFLICT (series_id) DO UPDATE SET run = excluded.run, bytes = excluded.bytes
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
            """
            SELECT s.ts, s.bytes FROM series n
            JOIN runs r ON r.series_id = n.id JOIN samples s ON s.run_id = r.id
            WHERE n.name = ? AND r.run = ? AND s.ts >= ? ORDER BY s.ts
            """,
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
                """
                SELECT t.bytes FROM typical_baselines t JOIN series n ON n.id = t.series_id
                WHERE n.name = ? AND t.run < ?
                """,
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

        // The series row exists: the samples above belong to it.
        try database.inTransaction {
            try database.execute(
                """
                INSERT OR REPLACE INTO baselines (series_id, run, bytes, origin)
                VALUES ((SELECT id FROM series WHERE name = ?), ?, ?, ?)
                """,
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
