import Foundation
import Testing
import MemorySaverCore
@testable import MemorySaverUI

@MainActor
final class FakeLoginItem: LoginItemControlling {
    var isEnabled = false
    var fail = false
    struct Failure: Error {}
    func setEnabled(_ enabled: Bool) throws {
        if fail { throw Failure() }
        isEnabled = enabled
    }
}

func makeDefaults() -> UserDefaults {
    let name = "MemorySaverUITests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
@Suite struct SettingsStoreTests {
    @Test func defaults() {
        let store = SettingsStore(defaults: makeDefaults(), loginItem: FakeLoginItem())
        #expect(store.appFootprintThresholdBytes == 2 << 30)
        #expect(store.appGrowthFactor == 1.5)
        #expect(store.windowServerGrowthThresholdBytes == 1 << 30)
        #expect(store.excludedAppIDs.isEmpty)
        #expect(store.notificationsEnabled)
        #expect(!store.launchAtLogin)
    }

    @Test func persistenceRoundTrip() {
        let defaults = makeDefaults()
        let first = SettingsStore(defaults: defaults, loginItem: FakeLoginItem())
        first.appFootprintThresholdBytes = 3 << 30
        first.appGrowthFactor = 2.0
        first.windowServerGrowthThresholdBytes = 512 << 20
        first.excludedAppIDs = ["com.a", "com.b"]
        first.notificationsEnabled = false

        let second = SettingsStore(defaults: defaults, loginItem: FakeLoginItem())
        #expect(second.appFootprintThresholdBytes == 3 << 30)
        #expect(second.appGrowthFactor == 2.0)
        #expect(second.windowServerGrowthThresholdBytes == 512 << 20)
        #expect(second.excludedAppIDs == ["com.a", "com.b"])
        #expect(!second.notificationsEnabled)
    }

    @Test func advisorSettingsMapping() {
        let store = SettingsStore(defaults: makeDefaults(), loginItem: FakeLoginItem())
        store.appFootprintThresholdBytes = 4 << 30
        store.appGrowthFactor = 1.8
        store.windowServerGrowthThresholdBytes = 2 << 30
        store.excludedAppIDs = ["x"]
        let advisor = store.advisorSettings
        #expect(advisor.appFootprintThresholdBytes == 4 << 30)
        #expect(advisor.appGrowthFactor == 1.8)
        #expect(advisor.windowServerGrowthThresholdBytes == 2 << 30)
        #expect(advisor.excludedAppIDs == ["x"])
    }

    @Test func launchAtLoginFailureRevertsToggle() {
        let login = FakeLoginItem()
        let store = SettingsStore(defaults: makeDefaults(), loginItem: login)
        store.setLaunchAtLogin(true)
        #expect(store.launchAtLogin)
        login.fail = true
        store.setLaunchAtLogin(false)
        #expect(store.launchAtLogin)
        #expect(store.launchAtLoginError != nil)
    }
}
