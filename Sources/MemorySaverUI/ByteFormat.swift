import Foundation
import MemorySaverCore

enum ByteFormat {
    /// Memory style (1024-based), e.g. "21.4 GB".
    static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// "+620 MB" when `bytes` exceeds `baseline`; nil otherwise.
    static func growth(of bytes: UInt64, over baseline: UInt64?) -> String? {
        guard let baseline, bytes > baseline else { return nil }
        return "+" + string(bytes - baseline)
    }
}

/// Growth wording that says what the baseline actually is.
enum GrowthLabel {
    enum Subject { case app, windowServer }

    /// e.g. "起動直後より +620 MB"; nil when there is no baseline or no growth. The main screen
    /// shows only the amount; this full wording is its tooltip.
    static func text(bytes: UInt64, baseline: Baseline?, subject: Subject) -> String? {
        guard let baseline, let growth = ByteFormat.growth(of: bytes, over: baseline.bytes) else {
            return nil
        }
        return switch (baseline.origin, subject) {
        case (.afterLaunch, .app): tr(.growthSinceLaunch, growth)
        case (.afterLaunch, .windowServer): tr(.growthSinceStartup, growth)
        case (.firstSeen, _): tr(.growthSinceMonitoringBegan, growth)
        }
    }
}
