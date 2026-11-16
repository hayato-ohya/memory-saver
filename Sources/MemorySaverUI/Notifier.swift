import Foundation
import UserNotifications
import MemorySaverCore

public enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined, denied, granted
}

/// The slice of UNUserNotificationCenter the notifier uses, so it can be tested without the
/// real notification center.
@MainActor
protocol NotificationDelivering {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async
    func post(title: String, body: String) async throws
}

@MainActor
struct SystemNotificationCenter: NotificationDelivering {
    func authorization() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .granted
        default: .denied
        }
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func post(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "memorysaver.recommendation", content: content, trigger: nil))
    }
}

@MainActor
public final class Notifier {
    public nonisolated static let renotifyInterval: TimeInterval = 24 * 60 * 60
    private static let defaultsKey = "lastNotifiedAt"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let isEnabled: () -> Bool
    private let injectedCenter: (any NotificationDelivering)?
    private var inFlight: Task<Void, Never>?

    public convenience init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        isEnabled: @escaping () -> Bool
    ) {
        self.init(defaults: defaults, now: now, isEnabled: isEnabled, center: nil)
    }

    init(
        defaults: UserDefaults, now: @escaping () -> Date, isEnabled: @escaping () -> Bool,
        center: (any NotificationDelivering)?
    ) {
        self.defaults = defaults
        self.now = now
        self.isEnabled = isEnabled
        self.injectedCenter = center
    }

    /// nil outside an app bundle: UNUserNotificationCenter.current() crashes there.
    private var center: (any NotificationDelivering)? {
        if let injectedCenter { return injectedCenter }
        return Bundle.main.bundleIdentifier != nil ? SystemNotificationCenter() : nil
    }

    /// Ids that should produce a notification now. Pure so the rules can be tested.
    nonisolated static func dueIDs(
        recommendations: [Recommendation],
        pressure: MemoryPressureLevel,
        enabled: Bool,
        lastNotified: [String: Date],
        now: Date,
        interval: TimeInterval = renotifyInterval
    ) -> [String] {
        guard enabled, pressure >= .warning else { return [] }
        return recommendations.map(\.id).filter { id in
            guard let last = lastNotified[id] else { return true }
            return now.timeIntervalSince(last) >= interval
        }
    }

    /// Returns immediately; the work runs in its own task. A call made while a previous one is
    /// still running is dropped, since the next sample brings fresh data anyway. Does nothing
    /// unless the user has already granted permission (see `requestAuthorizationIfNeeded`).
    public func notifyIfNeeded(recommendations: [Recommendation], pressure: MemoryPressureLevel) {
        guard inFlight == nil, let center else { return }
        inFlight = Task {
            await deliver(recommendations: recommendations, pressure: pressure, center: center)
            inFlight = nil
        }
    }

    /// Asks the system for permission once, if the user has not been asked yet. Call at launch
    /// and when the user turns notifications on. May wait for the user to answer the prompt.
    public func requestAuthorizationIfNeeded() async {
        guard let center, await center.authorization() == .notDetermined else { return }
        await center.requestAuthorization()
    }

    public func authorizationState() async -> NotificationAuthorization {
        await center?.authorization() ?? .notDetermined
    }

    /// Test hook: completes when no delivery is running.
    func waitUntilIdle() async { await inFlight?.value }

    private func deliver(
        recommendations: [Recommendation], pressure: MemoryPressureLevel,
        center: any NotificationDelivering
    ) async {
        let current = now()
        let last = loadLastNotified()
        let due = Self.dueIDs(
            recommendations: recommendations, pressure: pressure, enabled: isEnabled(),
            lastNotified: last, now: current)
        guard !due.isEmpty, await center.authorization() == .granted else { return }

        let dueRecommendations = recommendations.filter { due.contains($0.id) }
        do {
            try await center.post(
                title: tr(.notificationTitle), body: Self.body(for: dueRecommendations))
        } catch {
            return
        }

        var updated = last
        for id in due { updated[id] = current }
        // Drop entries older than the window so the dictionary does not grow forever.
        updated = updated.filter { current.timeIntervalSince($0.value) < Self.renotifyInterval }
        saveLastNotified(updated)
    }

    private static func body(for recommendations: [Recommendation]) -> String {
        let names = recommendations.compactMap { rec -> String? in
            if case .relaunchApp(let app, _) = rec { return app.displayName }
            return nil
        }
        var parts: [String] = []
        if !names.isEmpty {
            parts.append(tr(.notificationRelaunchApps, names.joined(separator: tr(.notificationAppListSeparator))))
        }
        if recommendations.contains(where: { if case .windowServerBloat = $0 { true } else { false } }) {
            parts.append(tr(.notificationWindowServer))
        }
        return parts.joined(separator: tr(.notificationSentenceSeparator))
    }

    private func loadLastNotified() -> [String: Date] {
        let raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveLastNotified(_ dates: [String: Date]) {
        defaults.set(dates.mapValues(\.timeIntervalSince1970), forKey: Self.defaultsKey)
    }
}
