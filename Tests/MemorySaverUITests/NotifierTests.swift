import Foundation
import Testing
import MemorySaverCore
@testable import MemorySaverUI

@Suite struct NotifierDueIDsTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let recs: [Recommendation] = [
        .relaunchApp(
            app: AppMemoryUsage(
                id: "com.foo", displayName: "Foo", bundleIdentifier: "com.foo", bundleURL: nil,
                mainPID: 1, footprintBytes: 3 << 30, launchDate: nil, processes: []),
            baseline: Baseline(bytes: 1 << 30, origin: .afterLaunch)),
        .windowServerBloat(currentBytes: 3 << 30, baseline: Baseline(bytes: 1 << 30, origin: .afterLaunch), suspects: []),
    ]

    private func due(
        pressure: MemoryPressureLevel = .warning, enabled: Bool = true,
        last: [String: Date] = [:], recommendations: [Recommendation]? = nil
    ) -> [String] {
        Notifier.dueIDs(
            recommendations: recommendations ?? recs, pressure: pressure, enabled: enabled,
            lastNotified: last, now: now)
    }

    @Test func normalPressureNeverNotifies() {
        #expect(due(pressure: .normal).isEmpty)
    }

    @Test func warningAndCriticalNotify() {
        #expect(due(pressure: .warning) == ["relaunch:com.foo", "windowserver"])
        #expect(due(pressure: .critical) == ["relaunch:com.foo", "windowserver"])
    }

    @Test func noRecommendationsNoNotification() {
        #expect(due(recommendations: []).isEmpty)
    }

    @Test func disabledNeverNotifies() {
        #expect(due(enabled: false).isEmpty)
    }

    @Test func suppressedWithin24Hours() {
        let last = ["relaunch:com.foo": now.addingTimeInterval(-23 * 3600)]
        #expect(due(last: last) == ["windowserver"])
    }

    @Test func dueAgainAfter24Hours() {
        let last = ["relaunch:com.foo": now.addingTimeInterval(-24 * 3600)]
        #expect(due(last: last) == ["relaunch:com.foo", "windowserver"])
    }
}

@MainActor
private final class FakeCenter: NotificationDelivering {
    var status: NotificationAuthorization
    var posted: [String] = []
    var authorizationRequests = 0
    /// While set, `authorization()` suspends until `release()` — like a pending system prompt.
    var gate: CheckedContinuation<Void, Never>?
    var blocks = false

    init(status: NotificationAuthorization) { self.status = status }

    func authorization() async -> NotificationAuthorization {
        if blocks { await withCheckedContinuation { gate = $0 } }
        return status
    }
    func requestAuthorization() async { authorizationRequests += 1 }
    func post(title: String, body: String) async throws { posted.append(body) }
    func release() { gate?.resume(); gate = nil; blocks = false }
}

@MainActor
@Suite struct NotifierDeliveryTests {
    private let recs: [Recommendation] = [
        .windowServerBloat(
            currentBytes: 3 << 30, baseline: Baseline(bytes: 1 << 30, origin: .afterLaunch), suspects: [])
    ]

    private func make(_ center: FakeCenter) -> Notifier {
        let defaults = UserDefaults(suiteName: "NotifierTests-\(UUID().uuidString)")!
        return Notifier(defaults: defaults, now: Date.init, isEnabled: { true }, center: center)
    }

    @Test func returnsImmediatelyWhileAuthorizationIsPending() async {
        let center = FakeCenter(status: .granted)
        center.blocks = true
        let notifier = make(center)
        notifier.notifyIfNeeded(recommendations: recs, pressure: .warning)
        // We got here without the center having answered, so the caller was not blocked.
        #expect(center.posted.isEmpty)
        for _ in 0..<20 where center.gate == nil { await Task.yield() }
        center.release()
        await notifier.waitUntilIdle()
        #expect(center.posted.count == 1)
    }

    @Test func overlappingCallsAreDropped() async {
        let center = FakeCenter(status: .granted)
        center.blocks = true
        let notifier = make(center)
        notifier.notifyIfNeeded(recommendations: recs, pressure: .warning)
        notifier.notifyIfNeeded(recommendations: recs, pressure: .warning)
        for _ in 0..<20 where center.gate == nil { await Task.yield() }
        center.release()
        await notifier.waitUntilIdle()
        #expect(center.posted.count == 1)
    }

    @Test func doesNothingUnlessGranted() async {
        for status in [NotificationAuthorization.denied, .notDetermined] {
            let center = FakeCenter(status: status)
            let notifier = make(center)
            notifier.notifyIfNeeded(recommendations: recs, pressure: .critical)
            await notifier.waitUntilIdle()
            #expect(center.posted.isEmpty)
            #expect(center.authorizationRequests == 0)
        }
    }

    @Test func notifyingAgainWithinADayIsSuppressed() async {
        let center = FakeCenter(status: .granted)
        let notifier = make(center)
        notifier.notifyIfNeeded(recommendations: recs, pressure: .warning)
        await notifier.waitUntilIdle()
        notifier.notifyIfNeeded(recommendations: recs, pressure: .warning)
        await notifier.waitUntilIdle()
        #expect(center.posted.count == 1)
    }

    @Test func authorizationIsRequestedOnlyWhenUndecided() async {
        let undecided = FakeCenter(status: .notDetermined)
        await make(undecided).requestAuthorizationIfNeeded()
        #expect(undecided.authorizationRequests == 1)
        let denied = FakeCenter(status: .denied)
        await make(denied).requestAuthorizationIfNeeded()
        #expect(denied.authorizationRequests == 0)
    }
}
