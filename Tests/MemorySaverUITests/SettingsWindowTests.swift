import AppKit
import Foundation
import Testing
@testable import MemorySaverUI

@MainActor
@Suite struct SettingsWindowTests {
    private func makeViewModel() -> MonitorViewModel {
        let defaults = UserDefaults(suiteName: "SettingsWindowTests-\(UUID().uuidString)")!
        return MonitorViewModel(settings: SettingsStore(defaults: defaults))
    }

    @Test func showSettingsOpensAVisibleWindowAndReusesIt() {
        _ = NSApplication.shared
        let viewModel = makeViewModel()

        viewModel.showSettings()
        let window = viewModel.settingsPresenter.window
        #expect(window?.isVisible == true)

        window?.close()
        #expect(window?.isVisible == false)

        viewModel.showSettings()
        #expect(viewModel.settingsPresenter.window === window)
        #expect(window?.isVisible == true)
        window?.close()
    }
}
