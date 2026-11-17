import AppKit
import SwiftUI
import MemorySaverCore

public struct SettingsView: View {
    let viewModel: MonitorViewModel
    let version: String?

    public init(viewModel: MonitorViewModel, version: String? = AppVersion.current) {
        self.viewModel = viewModel
        self.version = version
    }

    public var body: some View {
        @Bindable var settings = viewModel.settings
        Form {
            Section(tr(.settingsSectionThresholds)) {
                Stepper(
                    tr(.settingsThresholdAppFootprint, ByteFormat.string(settings.appFootprintThresholdBytes)),
                    value: gigabytes($settings.appFootprintThresholdBytes), in: 0.5...64, step: 0.5)
                Stepper(
                    tr(.settingsThresholdAppGrowth, settings.appGrowthFactor.formatted(.number.precision(.fractionLength(1)))),
                    value: $settings.appGrowthFactor, in: 1.1...5, step: 0.1)
                Stepper(
                    tr(.settingsThresholdWindowServerGrowth, ByteFormat.string(settings.windowServerGrowthThresholdBytes)),
                    value: gigabytes($settings.windowServerGrowthThresholdBytes), in: 0.25...16, step: 0.25)
            }
            Section(tr(.settingsSectionNotifications)) {
                Toggle(tr(.settingsNotificationsToggle), isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) {
                        Task { await viewModel.notificationsToggled() }
                    }
                if viewModel.notificationsDenied {
                    Text(tr(.settingsNotificationsDenied))
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle(tr(.settingsLaunchAtLoginToggle), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                if settings.launchAtLoginStatus == .needsApproval {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr(.settingsLaunchAtLoginNeedsApproval))
                            .font(.caption).foregroundStyle(.orange)
                        Button(tr(.settingsLaunchAtLoginOpenSettings)) { settings.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }
                if settings.launchAtLoginOutsideApplications {
                    Text(tr(.settingsLaunchAtLoginOutsideApplications))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section(tr(.settingsSectionExclusions)) {
                ExclusionList(viewModel: viewModel)
            }
            if let version {
                Section {
                    LabeledContent(tr(.settingsVersion), value: version)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 520)
        .task {
            settings.refreshLaunchAtLogin()
            await viewModel.refreshNotificationStatus()
        }
        // The user may have just changed the permission or the login item in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLaunchAtLogin()
            Task { await viewModel.refreshNotificationStatus() }
        }
    }

    /// Bridges a byte count to a GB value for `Stepper`.
    private func gigabytes(_ bytes: Binding<UInt64>) -> Binding<Double> {
        Binding(
            get: { Double(bytes.wrappedValue) / Double(1 << 30) },
            set: { bytes.wrappedValue = UInt64($0 * Double(1 << 30)) })
    }
}

extension AppMemoryUsage {
    /// What exclusions are matched against.
    var exclusionKey: String { bundleIdentifier ?? id }
}

private struct ExclusionList: View {
    let viewModel: MonitorViewModel

    var body: some View {
        let settings = viewModel.settings
        let names = Dictionary(
            (viewModel.snapshot?.apps ?? []).map { ($0.exclusionKey, $0.displayName) },
            uniquingKeysWith: { first, _ in first })

        if settings.excludedAppIDs.isEmpty {
            Text(tr(.settingsExclusionsEmpty)).foregroundStyle(.secondary)
        }
        ForEach(settings.excludedAppIDs.sorted(), id: \.self) { id in
            HStack {
                Text(names[id] ?? id)
                Spacer()
                Button(tr(.settingsExclusionsRemove)) { settings.excludedAppIDs.remove(id) }
            }
        }
        let candidates = (viewModel.snapshot?.apps ?? [])
            .filter { !settings.excludedAppIDs.contains($0.exclusionKey) }
        Menu(tr(.settingsExclusionsAddMenu)) {
            ForEach(candidates) { app in
                Button(app.displayName) { settings.excludedAppIDs.insert(app.exclusionKey) }
            }
        }
        .disabled(candidates.isEmpty)
    }
}

public enum AppVersion {
    /// Read from the app bundle, so it is nil when running outside one (tests, `swift run`).
    public static var current: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
