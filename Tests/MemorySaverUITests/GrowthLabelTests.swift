import Testing
import MemorySaverCore
@testable import MemorySaverUI

@Suite struct GrowthLabelTests {
    private let gb: UInt64 = 1 << 30

    @Test func wordingFollowsOriginAndSubject() {
        let launch = Baseline(bytes: gb, origin: .afterLaunch)
        let seen = Baseline(bytes: gb, origin: .firstSeen)
        let now = 2 * gb
        AppLanguage.$override.withValue(.japanese) {
            #expect(GrowthLabel.text(bytes: now, baseline: launch, subject: .app) == "起動直後より +1 GB")
            #expect(GrowthLabel.text(bytes: now, baseline: launch, subject: .windowServer) == "起動時より +1 GB")
            #expect(GrowthLabel.text(bytes: now, baseline: seen, subject: .app) == "監視開始時より +1 GB")
            #expect(GrowthLabel.text(bytes: now, baseline: seen, subject: .windowServer) == "監視開始時より +1 GB")
        }
    }

    @Test func englishWordingFollowsOriginAndSubject() {
        let launch = Baseline(bytes: gb, origin: .afterLaunch)
        let seen = Baseline(bytes: gb, origin: .firstSeen)
        let now = 2 * gb
        AppLanguage.$override.withValue(.english) {
            #expect(GrowthLabel.text(bytes: now, baseline: launch, subject: .app) == "+1 GB since launch")
            #expect(GrowthLabel.text(bytes: now, baseline: launch, subject: .windowServer) == "+1 GB since startup")
            #expect(GrowthLabel.text(bytes: now, baseline: seen, subject: .app) == "+1 GB since monitoring began")
            #expect(GrowthLabel.text(bytes: now, baseline: seen, subject: .windowServer) == "+1 GB since monitoring began")
        }
    }

    @Test func noBaselineOrNoGrowthShowsNothing() {
        #expect(GrowthLabel.text(bytes: gb, baseline: nil, subject: .app) == nil)
        #expect(GrowthLabel.text(bytes: gb, baseline: Baseline(bytes: 2 * gb, origin: .afterLaunch), subject: .app) == nil)
    }

    @Test func successHasNoMessage() {
        #expect(RelaunchMessage.text(for: .relaunched) == nil)
    }

    @Test func everyOtherRelaunchResultHasEnglishAndJapaneseText() throws {
        let results: [RelaunchResult] = [
            .notRunning, .failed("x"), .stoppedWaiting, .waitTimedOut, .quitButNotReopened("x"),
        ]
        for result in results {
            let ja = try #require(AppLanguage.$override.withValue(.japanese) { RelaunchMessage.text(for: result) })
            let en = try #require(AppLanguage.$override.withValue(.english) { RelaunchMessage.text(for: result) })
            #expect(ja != en)
            #expect(en.allSatisfy { $0.isASCII || $0 == "…" })
        }
    }
}
