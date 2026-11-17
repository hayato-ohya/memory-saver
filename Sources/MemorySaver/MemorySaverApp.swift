import Analysis
import MemorySaverCore
import MemorySaverUI
import Sampling
import SwiftUI

@main
struct MemorySaverApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(viewModel: model.viewModel)
        } label: {
            MenuBarLabel(viewModel: model.viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Builds the real samplers and store, and connects the engine to the view model.
@MainActor
final class AppModel {
    let viewModel = MonitorViewModel()
    private let notifier: Notifier
    private var engine: MonitorEngine?

    init() {
        let viewModel = viewModel
        let notifier = Notifier(isEnabled: {
            MainActor.assumeIsolated { viewModel.settings.notificationsEnabled }
        })
        self.notifier = notifier
        viewModel.notifier = notifier
        // Ask at launch, not when memory is already under pressure.
        if viewModel.settings.notificationsEnabled {
            Task { await notifier.requestAuthorizationIfNeeded() }
        }

        let updateChecker = UpdateChecker(
            currentVersion: AppVersion.current,
            isEnabled: { MainActor.assumeIsolated { viewModel.settings.updateCheckEnabled } })
        viewModel.updateChecker = updateChecker
        updateChecker.start()

        let store: TrendStore
        var storeWarning: String?
        do {
            store = try TrendStore(url: Self.historyURL())
        } catch {
            // Monitoring is still useful without persistence; baselines then restart with the app.
            guard let fallback = try? TrendStore(inMemory: true) else {
                viewModel.lastError = tr(.errorHistoryOpenFailed, error.localizedDescription)
                return
            }
            storeWarning = tr(.errorHistoryUnsaved, error.localizedDescription)
            store = fallback
        }
        viewModel.lastError = storeWarning

        viewModel.historyLoader = { series, since in try store.history(series: series, since: since) }

        let persistentWarning = storeWarning
        let engine = MonitorEngine(
            dependencies: .init(
                system: SystemSampler(),
                processes: ProcessSampler(),
                windowServer: WindowServerSampler(),
                runningApps: RunningAppProvider(),
                grouper: AppGrouper(),
                windows: WindowAttributor(),
                store: store,
                advisor: Advisor(store: store),
                // Without a boot time, every recorded WindowServer sample counts toward the baseline.
                bootTime: bootTime() ?? .distantPast),
            settings: { @MainActor in viewModel.settings.advisorSettings },
            onUpdate: { @MainActor update in
                if let snapshot = update.snapshot {
                    viewModel.snapshot = snapshot
                    viewModel.recommendations = update.recommendations
                    viewModel.windowServerBaseline = update.windowServerBaseline
                    viewModel.appBaselines = update.appBaselines
                    notifier.notifyIfNeeded(
                        recommendations: update.recommendations, pressure: snapshot.system.pressure)
                }
                viewModel.lastError = update.error ?? persistentWarning
            })
        self.engine = engine
        viewModel.onRefreshRequested = { Task { await engine.refreshNow() } }
        Task { await engine.start() }
    }

    private static func historyURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MemorySaver", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }
}
