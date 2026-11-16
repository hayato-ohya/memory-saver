import AppKit
import SwiftUI
import MemorySaverCore

/// Shows the settings in a window this app manages itself. SwiftUI's `Settings` scene and
/// `SettingsLink` do not open reliably from a `MenuBarExtra` in an app without a Dock icon.
@MainActor
final class SettingsWindowPresenter {
    private(set) var window: NSWindow?

    func show(viewModel: MonitorViewModel) {
        let window = window ?? makeWindow(viewModel: viewModel)
        self.window = window
        // An app without a Dock icon is not active when its menu bar item is clicked; without
        // this the window would open behind the frontmost app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(viewModel: MonitorViewModel) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(viewModel: viewModel)))
        window.title = tr(.settingsWindowTitle)
        window.styleMask = [.titled, .closable]
        // Kept and reused; the default would free the window on close and leave a dangling reference.
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
