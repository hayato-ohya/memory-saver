import Darwin
import Foundation
import MemorySaverCore
import Testing
@testable import Sampling

/// Smoke tests against the real machine.
struct LiveSamplingTests {
    @Test func systemSnapshotIsConsistent() throws {
        let snapshot = try SystemSampler().sample()
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        #expect(sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0)
        #expect(snapshot.totalBytes == memsize)
        #expect(snapshot.usedBytes > 0)
        #expect(snapshot.usedBytes < snapshot.totalBytes)
        #expect(snapshot.wiredBytes > 0)
        #expect(snapshot.wiredBytes < snapshot.usedBytes)
    }

    @Test func processSamplerIncludesCurrentProcess() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let processes = try ProcessSampler().sample()
        let me = try #require(processes.first { $0.pid == pid })
        #expect(me.footprintBytes > 0)
        #expect(me.parentPID == getppid())
        #expect(me.executablePath != nil)
        #expect(me.startTime != nil)
        #expect(!me.name.isEmpty)
        // WindowServer belongs to another user, so it must be skipped silently.
        #expect(!processes.contains { $0.name == "WindowServer" })
    }

    @Test func windowServerFootprintIsPlausible() async throws {
        let bytes = try #require(await WindowServerSampler().sample())
        #expect(bytes > 50 << 20)
    }

    @Test func bootTimeIsInThePast() throws {
        let boot = try #require(bootTime())
        #expect(boot < Date())
        #expect(boot > Date(timeIntervalSinceNow: -365 * 86_400))
    }

    @Test func runProcessTimesOut() async {
        let start = ContinuousClock.now
        let output = await runProcess("/bin/sleep", arguments: ["10"], timeout: .milliseconds(200))
        #expect(output == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func runProcessReturnsNilForMissingExecutable() async {
        #expect(await runProcess("/nonexistent/tool", arguments: [], timeout: .seconds(1)) == nil)
    }

    @Test func windowAttributorRuns() {
        // May be empty with no GUI session; must not crash and must be sorted.
        let result = WindowAttributor().sample()
        #expect(result.map(\.estimatedBackingBytes) == result.map(\.estimatedBackingBytes).sorted(by: >))
        #expect(!result.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    }

    @Test func runningAppProviderExcludesSelf() {
        let apps = RunningAppProvider().runningApps()
        #expect(!apps.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    }
}

@Test func windowServerStartTimeIsBetweenBootAndNow() async throws {
    let start = try #require(await WindowServerSampler().startTime())
    let boot = try #require(bootTime())
    #expect(start >= boot.addingTimeInterval(-1))
    #expect(start <= Date())
}
