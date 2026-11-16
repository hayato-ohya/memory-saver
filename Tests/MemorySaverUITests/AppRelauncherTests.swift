import Foundation
import Testing
import MemorySaverCore
@testable import MemorySaverUI

@MainActor
final class FakeAppController: AppControlling {
    /// Bundle identifier of the app currently running at the pid, nil when nothing is.
    var runningIdentifier: String? = "com.foo"
    /// When false the app ignores the quit request (waiting at a save prompt).
    var quitsWhenAsked: Bool
    /// Quits by itself after this many `isRunning` checks following the quit request.
    var quitsAfterChecks: Int?
    var quitRequested = false
    var checksSinceQuit = 0
    var existingPaths: Set<String> = ["/Applications/Foo.app"]
    var urlByIdentifier: [String: URL] = [:]
    var opened: [URL] = []
    var events: [String] = []
    var openError: Error?
    var onCheck: (() -> Void)?

    init(quitsWhenAsked: Bool = true) { self.quitsWhenAsked = quitsWhenAsked }

    func isRunning(pid: Int32, bundleIdentifier: String?) -> Bool {
        if quitRequested {
            checksSinceQuit += 1
            onCheck?()
            if let quitsAfterChecks, checksSinceQuit > quitsAfterChecks { runningIdentifier = nil }
        }
        return runningIdentifier != nil && runningIdentifier == bundleIdentifier
    }
    func requestQuit(pid: Int32) -> Bool {
        quitRequested = true
        events.append("quit")
        if quitsWhenAsked { runningIdentifier = nil }
        return true
    }
    func bundleExists(at url: URL) -> Bool { existingPaths.contains(url.path) }
    func urlForApplication(bundleIdentifier: String) -> URL? { urlByIdentifier[bundleIdentifier] }
    func open(bundleURL: URL) async throws {
        events.append("open")
        if let openError { throw openError }
        opened.append(bundleURL)
    }
}

func makeApp(
    bundleURL: URL? = URL(fileURLWithPath: "/Applications/Foo.app"), canRelaunch: Bool = true
) -> AppMemoryUsage {
    AppMemoryUsage(
        id: "com.foo", displayName: "Foo", bundleIdentifier: "com.foo", bundleURL: bundleURL,
        mainPID: 42, footprintBytes: 3 << 30, launchDate: nil, processes: [], canRelaunch: canRelaunch)
}

private struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

@MainActor
@Suite struct AppRelauncherTests {
    private func relauncher(
        _ controller: FakeAppController, timeout: Duration = .milliseconds(100)
    ) -> AppRelauncher {
        AppRelauncher(controller: controller, timeout: timeout, pollInterval: .milliseconds(5))
    }

    @Test func quitsThenReopens() async {
        let fake = FakeAppController()
        let result = await relauncher(fake).relaunch(makeApp())
        #expect(result == .relaunched)
        #expect(fake.events == ["quit", "open"])
        #expect(fake.opened == [URL(fileURLWithPath: "/Applications/Foo.app")])
    }

    @Test func defaultWaitIsFiveMinutes() {
        #expect(AppRelauncher.defaultTimeout == .seconds(300))
    }

    @Test func quittingLateStillReopens() async {
        let fake = FakeAppController(quitsWhenAsked: false)
        fake.quitsAfterChecks = 10
        let result = await relauncher(fake, timeout: .seconds(5)).relaunch(makeApp())
        #expect(result == .relaunched)
        #expect(fake.events == ["quit", "open"])
    }

    @Test func neverQuittingStopsAtTheCapWithoutReopening() async {
        let fake = FakeAppController(quitsWhenAsked: false)
        let result = await relauncher(fake).relaunch(makeApp())
        #expect(result == .waitTimedOut)
        #expect(fake.events == ["quit"])
    }

    @Test func stoppingTheWaitDoesNotReopen() async {
        let fake = FakeAppController(quitsWhenAsked: false)
        let relauncher = relauncher(fake, timeout: .seconds(5))
        let app = makeApp()
        let task = Task { await relauncher.relaunch(app) }
        fake.onCheck = { task.cancel() }
        let result = await task.value
        #expect(result == .stoppedWaiting)
        #expect(fake.events == ["quit"])
    }

    @Test func appQuittingJustAsTheUserStopsWaitingIsNotReopened() async {
        let fake = FakeAppController(quitsWhenAsked: false)
        let relauncher = relauncher(fake, timeout: .seconds(5))
        let app = makeApp()
        let task = Task { await relauncher.relaunch(app) }
        fake.onCheck = { fake.runningIdentifier = nil; task.cancel() }
        #expect(await task.value == .stoppedWaiting)
        #expect(fake.opened.isEmpty)
    }

    @Test func notRunning() async {
        let fake = FakeAppController()
        fake.runningIdentifier = nil
        let result = await relauncher(fake).relaunch(makeApp())
        #expect(result == .notRunning)
        #expect(!fake.quitRequested)
    }

    @Test func pidNowBelongsToAnotherApp() async {
        let fake = FakeAppController()
        fake.runningIdentifier = "com.other"
        let result = await relauncher(fake).relaunch(makeApp())
        #expect(result == .notRunning)
        #expect(!fake.quitRequested)
        #expect(fake.opened.isEmpty)
    }

    @Test func noBundleURL() async {
        let fake = FakeAppController()
        let app = makeApp(bundleURL: nil)
        #expect(!AppRelauncher.canRelaunch(app))
        guard case .failed = await relauncher(fake).relaunch(app) else {
            Issue.record("expected failed"); return
        }
        #expect(!fake.quitRequested)
    }

    @Test func systemAgentIsRefusedEvenIfCalled() async {
        let fake = FakeAppController()
        let app = makeApp(canRelaunch: false)
        #expect(!AppRelauncher.canRelaunch(app))
        guard case .failed = await relauncher(fake).relaunch(app) else {
            Issue.record("expected failed"); return
        }
        #expect(!fake.quitRequested)
        #expect(fake.opened.isEmpty)
    }

    @Test func movedBundleIsLookedUpByIdentifier() async {
        let fake = FakeAppController()
        fake.existingPaths = []
        let moved = URL(fileURLWithPath: "/Applications/Utilities/Foo.app")
        fake.urlByIdentifier["com.foo"] = moved
        let result = await relauncher(fake).relaunch(makeApp())
        #expect(result == .relaunched)
        #expect(fake.opened == [moved])
    }

    @Test func missingBundleQuitsNothing() async {
        let fake = FakeAppController()
        fake.existingPaths = []
        guard case .failed = await relauncher(fake).relaunch(makeApp()) else {
            Issue.record("expected failed"); return
        }
        #expect(!fake.quitRequested)
        #expect(fake.opened.isEmpty)
    }

    @Test func quitButReopenFailedIsReportedAsSuch() async {
        let fake = FakeAppController()
        fake.openError = Boom()
        let result = await relauncher(fake).relaunch(makeApp())
        #expect(result == .quitButNotReopened("boom"))
        AppLanguage.$override.withValue(.japanese) {
            #expect(RelaunchMessage.text(for: result)?.hasPrefix("終了しましたが、開き直せませんでした") == true)
        }
        AppLanguage.$override.withValue(.english) {
            #expect(RelaunchMessage.text(for: result) == "The app quit but couldn't be reopened (boom). Open it yourself.")
        }
    }
}

@MainActor
@Suite struct MonitorViewModelRelaunchTests {
    private func makeViewModel(_ fake: FakeAppController, timeout: Duration = .milliseconds(100))
        -> MonitorViewModel
    {
        let defaults = UserDefaults(suiteName: "VMTests-\(UUID().uuidString)")!
        return MonitorViewModel(
            settings: SettingsStore(defaults: defaults),
            relauncher: AppRelauncher(controller: fake, timeout: timeout, pollInterval: .milliseconds(5)),
            followUpRefreshDelay: .milliseconds(30))
    }

    @Test func refreshesRightAwayAndAgainLater() async throws {
        let fake = FakeAppController()
        let viewModel = makeViewModel(fake)
        var refreshes = 0
        viewModel.onRefreshRequested = { refreshes += 1 }
        viewModel.relaunch(makeApp())
        #expect(viewModel.relaunchStates["com.foo"] == .running)
        try await Task.sleep(for: .milliseconds(400))
        // A successful relaunch leaves no message behind.
        #expect(viewModel.relaunchStates["com.foo"] == nil)
        #expect(viewModel.relaunchNames["com.foo"] == nil)
        #expect(refreshes == 2)
    }

    @Test func stopWaitingCancelsWithoutReopening() async throws {
        let fake = FakeAppController(quitsWhenAsked: false)
        let viewModel = makeViewModel(fake, timeout: .seconds(30))
        viewModel.relaunch(makeApp())
        try await Task.sleep(for: .milliseconds(50))
        viewModel.stopWaiting(for: "com.foo")
        try await Task.sleep(for: .milliseconds(100))
        #expect(viewModel.relaunchStates["com.foo"] == .finished(.stoppedWaiting))
        #expect(fake.opened.isEmpty)
    }
}
