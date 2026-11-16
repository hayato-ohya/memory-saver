import AppKit
import MemorySaverCore

public enum RelaunchResult: Equatable, Sendable {
    /// The app quit and was reopened.
    case relaunched
    /// The app is no longer running (or the pid now belongs to something else); nothing was quit.
    case notRunning
    /// Nothing was quit: the request was refused or the app could not be found.
    case failed(String)
    /// The user stopped waiting. The app was not reopened (and is never force-quit).
    case stoppedWaiting
    /// The app did not quit within the wait limit. It is not reopened if it quits later.
    case waitTimedOut
    /// The app quit but could not be opened again; the user has to open it by hand.
    case quitButNotReopened(String)
}

/// The system calls behind a relaunch, so the sequencing can be tested with a fake.
@MainActor
public protocol AppControlling {
    /// True if the process `pid` is a live app with this bundle identifier. A pid alone is not
    /// enough: the snapshot can be a minute old and pids get reused.
    func isRunning(pid: Int32, bundleIdentifier: String?) -> Bool
    /// Asks the app to quit normally. Returns false if the request could not be sent.
    func requestQuit(pid: Int32) -> Bool
    func bundleExists(at url: URL) -> Bool
    func urlForApplication(bundleIdentifier: String) -> URL?
    func open(bundleURL: URL) async throws
}

@MainActor
public struct SystemAppController: AppControlling {
    public init() {}

    public func isRunning(pid: Int32, bundleIdentifier: String?) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return false
        }
        return app.bundleIdentifier == bundleIdentifier
    }

    public func requestQuit(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return false
        }
        // Normal quit only: the app may prompt for unsaved documents. Never forceTerminate().
        return app.terminate()
    }

    public func bundleExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func urlForApplication(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    public func open(bundleURL: URL) async throws {
        _ = try await NSWorkspace.shared.openApplication(
            at: bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

@MainActor
public struct AppRelauncher {
    public static let defaultTimeout: Duration = .seconds(5 * 60)

    private let controller: any AppControlling
    private let timeout: Duration
    private let pollInterval: Duration

    public init(
        controller: any AppControlling = SystemAppController(),
        timeout: Duration = AppRelauncher.defaultTimeout,
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.controller = controller
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public static func canRelaunch(_ app: AppMemoryUsage) -> Bool {
        app.canRelaunch && app.bundleURL != nil
    }

    /// Cancelling the calling task stops the wait; the app is then left alone and not reopened.
    public func relaunch(_ app: AppMemoryUsage) async -> RelaunchResult {
        guard Self.canRelaunch(app), let savedURL = app.bundleURL else {
            return .failed(tr(.relaunchErrorUnsupported))
        }
        let identifier = app.bundleIdentifier
        guard controller.isRunning(pid: app.mainPID, bundleIdentifier: identifier) else {
            return .notRunning
        }
        // The app may have been updated or moved since the snapshot was taken.
        let url: URL
        if controller.bundleExists(at: savedURL) {
            url = savedURL
        } else if let identifier, let found = controller.urlForApplication(bundleIdentifier: identifier) {
            url = found
        } else {
            return .failed(tr(.relaunchErrorAppNotFound))
        }
        guard controller.requestQuit(pid: app.mainPID) else {
            return .failed(tr(.relaunchErrorQuitRefused))
        }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while controller.isRunning(pid: app.mainPID, bundleIdentifier: identifier) {
            if Task.isCancelled { return .stoppedWaiting }
            if clock.now >= deadline { return .waitTimedOut }
            try? await Task.sleep(for: pollInterval)
        }
        if Task.isCancelled { return .stoppedWaiting }

        do {
            try await controller.open(bundleURL: url)
            return .relaunched
        } catch {
            return .quitButNotReopened(error.localizedDescription)
        }
    }
}
