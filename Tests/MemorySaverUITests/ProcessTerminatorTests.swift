import Darwin
import Foundation
import Testing
import MemorySaverCore
@testable import MemorySaverUI

final class FakeProcessController: ProcessControlling, @unchecked Sendable {
    var live: [Int32: LiveProcessIdentity] = [:]
    var sendError: Int32?
    var signalled: [Int32] = []

    func identity(pid: Int32) -> LiveProcessIdentity? { live[pid] }
    func sendTerminate(pid: Int32) -> Int32? {
        signalled.append(pid)
        return sendError
    }
}

private let start = Date(timeIntervalSince1970: 1_700_000_000)
private let helperPath = "/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper"

private func helper(pid: Int32 = 100) -> ProcessSample {
    ProcessSample(
        pid: pid, parentPID: 42, name: "Foo Helper", executablePath: helperPath,
        footprintBytes: 1 << 30, startTime: start, detail: "renderer")
}

private func app(canRelaunch: Bool = true) -> AppMemoryUsage {
    let main = ProcessSample(
        pid: 42, parentPID: 1, name: "Foo", executablePath: "/Applications/Foo.app/Contents/MacOS/Foo",
        footprintBytes: 1 << 30, startTime: start)
    return AppMemoryUsage(
        id: "com.foo", displayName: "Foo", bundleIdentifier: "com.foo",
        bundleURL: URL(fileURLWithPath: "/Applications/Foo.app"), mainPID: 42,
        footprintBytes: 2 << 30, launchDate: nil, processes: [main, helper()], canRelaunch: canRelaunch)
}

private func controller(owned: Bool = true) -> FakeProcessController {
    let fake = FakeProcessController()
    fake.live[100] = LiveProcessIdentity(executablePath: helperPath, startTime: start, isOwnedByCurrentUser: owned)
    return fake
}

@Suite struct ProcessTerminatorTests {
    @Test func signalsAMatchingHelper() {
        let fake = controller()
        #expect(ProcessTerminator(controller: fake).terminate(helper(), in: app()) == .requested)
        #expect(fake.signalled == [100])
    }

    @Test func neverSignalsTheMainProcess() {
        let fake = controller()
        let main = app().processes[0]
        #expect(!ProcessTerminator.canTerminate(main, in: app()))
        guard case .failed = ProcessTerminator(controller: fake).terminate(main, in: app()) else {
            Issue.record("expected failure"); return
        }
        #expect(fake.signalled.isEmpty)
    }

    @Test func neverSignalsSystemAgents() {
        let fake = controller()
        #expect(!ProcessTerminator.canTerminate(helper(), in: app(canRelaunch: false)))
        _ = ProcessTerminator(controller: fake).terminate(helper(), in: app(canRelaunch: false))
        #expect(fake.signalled.isEmpty)
    }

    @Test func skipsAReusedPid() {
        let fake = controller()
        fake.live[100]?.startTime = start.addingTimeInterval(60)
        #expect(ProcessTerminator(controller: fake).terminate(helper(), in: app()) == .notRunning)
        fake.live[100] = LiveProcessIdentity(executablePath: "/bin/other", startTime: start, isOwnedByCurrentUser: true)
        #expect(ProcessTerminator(controller: fake).terminate(helper(), in: app()) == .notRunning)
        #expect(fake.signalled.isEmpty)
    }

    @Test func skipsAnExitedProcess() {
        let fake = FakeProcessController()
        #expect(ProcessTerminator(controller: fake).terminate(helper(), in: app()) == .notRunning)
        #expect(fake.signalled.isEmpty)
    }

    @Test func refusesOtherUsersProcesses() {
        let fake = controller(owned: false)
        guard case .failed = ProcessTerminator(controller: fake).terminate(helper(), in: app()) else {
            Issue.record("expected failure"); return
        }
        #expect(fake.signalled.isEmpty)
    }

    @Test func reportsSignalErrors() {
        let fake = controller()
        fake.sendError = ESRCH
        #expect(ProcessTerminator(controller: fake).terminate(helper(), in: app()) == .notRunning)
        fake.sendError = EPERM
        guard case .failed = ProcessTerminator(controller: fake).terminate(helper(), in: app()) else {
            Issue.record("expected failure"); return
        }
    }

    /// End to end against a real child process: it is asked to quit and exits.
    @Test func terminatesARealProcess() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier
        let live = try #require(SystemProcessController().identity(pid: pid))
        #expect(live.isOwnedByCurrentUser)
        let sample = ProcessSample(
            pid: pid, parentPID: getpid(), name: "sleep", executablePath: live.executablePath,
            footprintBytes: 0, startTime: live.startTime)
        var owner = app()
        owner.processes.append(sample)
        #expect(ProcessTerminator().terminate(sample, in: owner) == .requested)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
    }
}

@MainActor
@Suite struct MonitorViewModelTerminationTests {
    private func makeViewModel(_ fake: FakeProcessController) -> MonitorViewModel {
        let defaults = UserDefaults(suiteName: "VMTerminateTests-\(UUID().uuidString)")!
        return MonitorViewModel(
            settings: SettingsStore(defaults: defaults),
            terminator: ProcessTerminator(controller: fake),
            followUpRefreshDelay: .milliseconds(30))
    }

    @Test func refreshesAfterwardsAndLeavesNoMessageOnSuccess() async throws {
        let viewModel = makeViewModel(controller())
        var refreshes = 0
        viewModel.onRefreshRequested = { refreshes += 1 }
        viewModel.terminate(helper(), in: app())
        #expect(viewModel.processTerminationMessages["com.foo"] == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(refreshes == 1)
    }

    @Test func showsAndDismissesAMessageWhenNothingWasDone() {
        let viewModel = makeViewModel(FakeProcessController())
        viewModel.terminate(helper(), in: app())
        #expect(viewModel.processTerminationMessages["com.foo"] != nil)
        viewModel.dismissProcessTerminationMessage(for: "com.foo")
        #expect(viewModel.processTerminationMessages["com.foo"] == nil)
    }
}
