import Foundation
import Observation
import MemorySaverCore

public enum RelaunchState: Equatable {
    case running
    case finished(RelaunchResult)
}

@MainActor
@Observable
public final class MonitorViewModel {
    // Pushed in by the engine.
    public var snapshot: MemorySnapshot?
    public var recommendations: [Recommendation] = []
    public var windowServerBaseline: Baseline?
    /// Keyed by app id.
    public var appBaselines: [String: Baseline] = [:]
    public var lastError: String?
    /// Notifications are on in the app but refused in System Settings. Updated by
    /// `refreshNotificationStatus()`.
    public var notificationsDenied = false

    /// Set by the engine; called by the refresh button.
    @ObservationIgnored public var onRefreshRequested: (() -> Void)?
    /// Set by the app; read by the history charts. Without it the charts stay empty.
    @ObservationIgnored public var historyLoader: HistoryLoader?

    public let settings: SettingsStore
    /// Keyed by app id.
    public private(set) var relaunchStates: [String: RelaunchState] = [:]
    /// Display names of apps with a relaunch state, for showing a result after the app has
    /// left the ranking.
    public private(set) var relaunchNames: [String: String] = [:]

    /// Apps whose process breakdown is open in the ranking.
    public private(set) var expandedAppIDs: Set<String> = []
    /// Whether WindowServer's history chart is open.
    public private(set) var isWindowServerExpanded = false

    @ObservationIgnored private let relauncher: AppRelauncher
    @ObservationIgnored private let followUpRefreshDelay: Duration
    @ObservationIgnored private var relaunchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored public var notifier: Notifier?
    @ObservationIgnored let settingsPresenter = SettingsWindowPresenter()

    public init(
        settings: SettingsStore = SettingsStore(),
        relauncher: AppRelauncher = AppRelauncher(),
        notifier: Notifier? = nil,
        followUpRefreshDelay: Duration = .seconds(5)
    ) {
        self.settings = settings
        self.relauncher = relauncher
        self.notifier = notifier
        self.followUpRefreshDelay = followUpRefreshDelay
    }

    var recommendedAppIDs: Set<String> {
        Set(recommendations.compactMap { rec in
            if case .relaunchApp(let app, _) = rec { app.id } else { nil }
        })
    }

    public var pressure: MemoryPressureLevel { snapshot?.system.pressure ?? .normal }

    public func requestRefresh() { onRefreshRequested?() }

    public func toggleExpanded(_ appID: String) {
        if !expandedAppIDs.insert(appID).inserted { expandedAppIDs.remove(appID) }
    }

    public func toggleWindowServerExpanded() { isWindowServerExpanded.toggle() }

    public func showSettings() { settingsPresenter.show(viewModel: self) }

    public func relaunch(_ app: AppMemoryUsage) {
        guard relaunchStates[app.id] != .running else { return }
        relaunchStates[app.id] = .running
        relaunchNames[app.id] = app.displayName
        relaunchTasks[app.id] = Task {
            let result = await relauncher.relaunch(app)
            relaunchTasks[app.id] = nil
            if RelaunchMessage.text(for: result) != nil {
                relaunchStates[app.id] = .finished(result)
            } else {
                // Success speaks for itself: the app is back in the list with its new size.
                relaunchStates[app.id] = nil
                relaunchNames[app.id] = nil
            }
            // Drop the old instance from the popover now, and pick up the new one once it has appeared.
            requestRefresh()
            try? await Task.sleep(for: followUpRefreshDelay)
            requestRefresh()
        }
    }

    /// Stops waiting for the app to quit. The app is not reopened and never force-quit.
    public func stopWaiting(for appID: String) {
        relaunchTasks[appID]?.cancel()
    }

    /// Called when the notifications toggle is switched on, and when the settings window is shown.
    public func notificationsToggled() async {
        if settings.notificationsEnabled { await notifier?.requestAuthorizationIfNeeded() }
        await refreshNotificationStatus()
    }

    public func refreshNotificationStatus() async {
        guard let notifier else { notificationsDenied = false; return }
        let state = await notifier.authorizationState()
        notificationsDenied = settings.notificationsEnabled && state == .denied
    }

    public func dismissRelaunchResult(for appID: String) {
        if case .finished = relaunchStates[appID] {
            relaunchStates[appID] = nil
            relaunchNames[appID] = nil
        }
    }
}
