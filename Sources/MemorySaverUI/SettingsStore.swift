import Foundation
import Observation
import ServiceManagement
import MemorySaverCore

/// Register/unregister seam so `SettingsStore` can be tested without touching the real login items.
@MainActor
public protocol LoginItemControlling {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
public struct SystemLoginItem: LoginItemControlling {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
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
    public private(set) var launchAtLogin: Bool
    public private(set) var launchAtLoginError: String?

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
        launchAtLogin = loginItem.isEnabled
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
        launchAtLogin = loginItem.isEnabled
    }
}
