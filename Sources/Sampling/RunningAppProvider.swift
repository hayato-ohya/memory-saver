import AppKit
import MemorySaverCore

public struct RunningAppProvider: RunningAppProviding {
    public init() {}

    public func runningApps() -> [RunningAppInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier > 0, app.processIdentifier != ownPID,
                  app.activationPolicy == .regular || app.activationPolicy == .accessory
            else { return nil }
            let name = app.localizedName
                ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                ?? app.executableURL?.lastPathComponent
                ?? "pid \(app.processIdentifier)"
            return RunningAppInfo(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                displayName: name,
                bundleURL: app.bundleURL,
                launchDate: app.launchDate
            )
        }
    }
}
