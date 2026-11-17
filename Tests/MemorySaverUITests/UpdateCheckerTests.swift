import Foundation
import Testing
@testable import MemorySaverUI

@Suite struct ReleaseVersionTests {
    @Test func comparesNumbersNotStrings() {
        #expect(ReleaseVersion.isNewer("0.10", than: "0.9") == true)
        #expect(ReleaseVersion.isNewer("v0.4", than: "0.3") == true)
        #expect(ReleaseVersion.isNewer("0.3", than: "0.3") == false)
        #expect(ReleaseVersion.isNewer("1.0", than: "1") == false)
        #expect(ReleaseVersion.isNewer("0.2.9", than: "0.3") == false)
        #expect(ReleaseVersion.isNewer("0.4-beta", than: "0.3") == nil)
    }

    @Test func parsesGitHubPayload() throws {
        let json = #"{"tag_name":"v0.4","html_url":"https://github.com/o/r/releases/tag/v0.4","draft":false}"#
        let release = try GitHubReleases.parse(Data(json.utf8))
        #expect(release == ReleaseInfo(version: "0.4", url: URL(string: "https://github.com/o/r/releases/tag/v0.4")!))
    }
}

@MainActor
@Suite struct UpdateCheckerTests {
    final class Fake: @unchecked Sendable {
        var release = ReleaseInfo(version: "0.4", url: URL(string: "https://example.com/r")!)
        var fail = false
        var calls = 0
    }

    private func make(
        _ fake: Fake, version: String? = "0.3", defaults: UserDefaults = makeDefaults(),
        now: @escaping () -> Date = Date.init, enabled: Bool = true
    ) -> UpdateChecker {
        UpdateChecker(
            currentVersion: version, defaults: defaults, now: now,
            fetch: {
                fake.calls += 1
                if fake.fail { throw URLError(.notConnectedToInternet) }
                return fake.release
            },
            isEnabled: { enabled })
    }

    @Test func findsNewerRelease() async {
        let fake = Fake()
        let checker = make(fake)
        await checker.checkIfDue()
        #expect(checker.available?.version == "0.4")
    }

    @Test func sameVersionIsUpToDate() async {
        let fake = Fake()
        fake.release.version = "0.3"
        let checker = make(fake)
        await checker.checkNow()
        #expect(checker.available == nil)
        #expect(checker.status == .upToDate)
    }

    @Test func checksAtMostOnceADay() async {
        let fake = Fake()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let checker = make(fake, now: { clock })
        await checker.checkIfDue()
        clock += 23 * 3600
        await checker.checkIfDue()
        #expect(fake.calls == 1)
        clock += 2 * 3600
        await checker.checkIfDue()
        #expect(fake.calls == 2)
    }

    @Test func disabledNeverFetches() async {
        let fake = Fake()
        let checker = make(fake, enabled: false)
        await checker.checkIfDue()
        #expect(fake.calls == 0)
    }

    @Test func noVersionNeverFetches() async {
        let fake = Fake()
        let checker = make(fake, version: nil)
        await checker.checkNow()
        #expect(fake.calls == 0)
    }

    @Test func failureKeepsWhatIsKnown() async {
        let fake = Fake()
        let checker = make(fake)
        await checker.checkNow()
        fake.fail = true
        await checker.checkNow()
        #expect(checker.status == .failed)
        #expect(checker.available?.version == "0.4")
    }

    @Test func rememberedReleaseIsDroppedAfterUpdating() async {
        let defaults = makeDefaults()
        await make(Fake(), defaults: defaults).checkNow()
        #expect(make(Fake(), version: "0.3", defaults: defaults).available?.version == "0.4")
        #expect(make(Fake(), version: "0.4", defaults: defaults).available == nil)
    }
}
