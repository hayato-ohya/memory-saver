import Foundation
import Observation
import ServiceManagement
import MemorySaverCore

public enum LoginItemStatus: Sendable, Equatable {
    case off
    case on
    /// Registered, but switched off in System Settings > General > Login Items (or awaiting
    /// approval there), so it will not open at login.
    case needsApproval
}

/// Register/unregister seam so `SettingsStore` can be tested without touching the real login items.
@MainActor
public protocol LoginItemControlling {
    var status: LoginItemStatus { get }
    /// Whether the app runs from an Applications folder. A login item points at the app's
    /// location, so one registered from a build folder breaks when that copy is replaced.
    var isInApplicationsFolder: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

@MainActor
public struct SystemLoginItem: LoginItemControlling {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    public var isInApplicationsFolder: Bool {
        Self.isInApplicationsFolder(Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    nonisolated static func isInApplicationsFolder(_ bundle: URL, home: URL) -> Bool {
        let folder = bundle.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path
        let applications = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        return applications.contains { folder == $0 || folder.hasPrefix($0 + "/") }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
@Observable
public final class SettingsStore {
    private enum Key {
        static let appThreshold = "appFootprintThresholdBytes"
        static let growthFactor = "appGrowthFactor"
        static let windowServerThreshold = "windowServerGrowthThresholdBytes"
        static let excluded = "excludedAppIDs"
        static let notifications = "notificationsEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loginItem: any LoginItemControlling

    public var appFootprintThresholdBytes: UInt64 {
        didSet { defaults.set(Double(appFootprintThresholdBytes), forKey: Key.appThreshold) }
    }
    public var appGrowthFactor: Double {
        didSet { defaults.set(appGrowthFactor, forKey: Key.growthFactor) }
    }
    public var windowServerGrowthThresholdBytes: UInt64 {
        didSet { defaults.set(Double(windowServerGrowthThresholdBytes), forKey: Key.windowServerThreshold) }
    }
    public var excludedAppIDs: Set<String> {
        didSet { defaults.set(excludedAppIDs.sorted(), forKey: Key.excluded) }
    }
    public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) }
    }
    /// Mirrors the real login item state; the system is the source of truth, not UserDefaults.
    public private(set) var launchAtLoginStatus: LoginItemStatus
    public private(set) var launchAtLoginError: String?
    /// The switch is on whenever the item is registered, including while it awaits approval.
    public var launchAtLogin: Bool { launchAtLoginStatus != .off }
    /// Worth warning about only once the user wants the app to open at login.
    public var launchAtLoginOutsideApplications: Bool { launchAtLogin && !loginItem.isInApplicationsFolder }

    public init(
        defaults: UserDefaults = .standard,
        loginItem: any LoginItemControlling = SystemLoginItem()
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        let base = AdvisorSettings()
        appFootprintThresholdBytes = (defaults.object(forKey: Key.appThreshold) as? Double)
            .map { UInt64($0) } ?? base.appFootprintThresholdBytes
        appGrowthFactor = defaults.object(forKey: Key.growthFactor) as? Double ?? base.appGrowthFactor
        windowServerGrowthThresholdBytes = (defaults.object(forKey: Key.windowServerThreshold) as? Double)
            .map { UInt64($0) } ?? base.windowServerGrowthThresholdBytes
        excludedAppIDs = Set(defaults.stringArray(forKey: Key.excluded) ?? [])
        notificationsEnabled = defaults.object(forKey: Key.notifications) as? Bool ?? true
        launchAtLoginStatus = loginItem.status
    }

    public var advisorSettings: AdvisorSettings {
        AdvisorSettings(
            appFootprintThresholdBytes: appFootprintThresholdBytes,
            appGrowthFactor: appGrowthFactor,
            windowServerGrowthThresholdBytes: windowServerGrowthThresholdBytes,
            excludedAppIDs: excludedAppIDs
        )
    }

    /// On failure (e.g. not running from an app bundle) the toggle snaps back to the real state.
    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = tr(.settingsLaunchAtLoginError, error.localizedDescription)
        }
        launchAtLoginStatus = loginItem.status
    }

    /// Re-reads the state, which the user can change in System Settings at any time.
    public func refreshLaunchAtLogin() {
        launchAtLoginStatus = loginItem.status
    }

    public func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }
}
