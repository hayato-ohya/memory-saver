import Foundation
import MemorySaverCore

public struct Advisor: Advising {
    private let store: any TrendStoring

    public init(store: any TrendStoring) {
        self.store = store
    }

    public func recommendations(
        for snapshot: MemorySnapshot, windowServerStart: Date, settings: AdvisorSettings
    ) throws -> [Recommendation] {
        var result: [Recommendation] = []

        if let current = snapshot.windowServerBytes,
            let baseline = try store.windowServerBaseline(since: windowServerStart),
            current >= baseline.bytes,
            current - baseline.bytes >= settings.windowServerGrowthThresholdBytes
        {
            result.append(.windowServerBloat(
                currentBytes: current, baseline: baseline,
                suspects: Array(snapshot.windows.prefix(max(0, settings.windowServerSuspectCount)))))
        }

        var candidates: [(reclaimable: UInt64, recommendation: Recommendation)] = []
        for app in snapshot.apps {
            guard app.canRelaunch,
                app.footprintBytes >= settings.appFootprintThresholdBytes,
                !settings.excludedAppIDs.contains(app.bundleIdentifier ?? app.id),
                let baseline = try store.appBaseline(appID: app.id, launchDate: app.launchDate),
                app.footprintBytes >= baseline.bytes,
                Double(app.footprintBytes) >= Double(baseline.bytes) * settings.appGrowthFactor
            else { continue }
            candidates.append((
                app.footprintBytes - baseline.bytes, .relaunchApp(app: app, baseline: baseline)))
        }
        // Stable for equal amounts: keep the snapshot's footprint order.
        let ordered = candidates.enumerated().sorted {
            ($0.element.reclaimable, $1.offset) > ($1.element.reclaimable, $0.offset)
        }
        result += ordered.map(\.element.recommendation)
        return result
    }
}
