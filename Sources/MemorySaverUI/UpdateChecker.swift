import Foundation
import Observation
import MemorySaverCore

/// A published release.
public struct ReleaseInfo: Codable, Equatable, Sendable {
    public var version: String
    /// The release's page, where the zip file is.
    public var url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

public typealias ReleaseFetcher = @Sendable () async throws -> ReleaseInfo

enum ReleaseVersion {
    /// Compares dotted version numbers ("0.10" > "0.9", "1.0" == "1"). A leading "v" is ignored.
    /// nil when either side is not made of numbers.
    static func isNewer(_ candidate: String, than current: String) -> Bool? {
        guard let a = parts(candidate), let b = parts(current) else { return nil }
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }

    /// "v0.3" → "0.3".
    static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    private static func parts(_ version: String) -> [Int]? {
        let numbers = normalized(version).split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
        return numbers.compactMap { $0 }
    }
}

/// Reads the latest release from GitHub. The request carries nothing about the user or the Mac.
public enum GitHubReleases {
    static let latestURL = URL(string: "https://api.github.com/repos/hayato-ohya/memory-saver/releases/latest")!

    public static let fetchLatest: ReleaseFetcher = {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MemorySaver-update-check", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try parse(data)
    }

    /// The `releases/latest` endpoint already leaves out drafts and pre-releases.
    static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Payload: Decodable {
            var tag_name: String
            var html_url: URL
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return ReleaseInfo(version: ReleaseVersion.normalized(payload.tag_name), url: payload.html_url)
    }
}

/// Checks GitHub for a newer release about once a day, and only while the user allows it.
@MainActor
@Observable
public final class UpdateChecker {
    public enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case failed
    }

    private enum Key {
        static let lastCheck = "updateLastCheck"
        static let latest = "updateLatestRelease"
    }

    static let interval: TimeInterval = 24 * 3600

    /// A release newer than this copy, if the last check found one.
    public private(set) var available: ReleaseInfo?
    public private(set) var status: Status = .idle
    public private(set) var lastCheck: Date?

    @ObservationIgnored public let currentVersion: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let fetch: ReleaseFetcher
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private var loop: Task<Void, Never>?

    public init(
        currentVersion: String?,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping ReleaseFetcher = GitHubReleases.fetchLatest,
        isEnabled: @escaping () -> Bool
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        self.isEnabled = isEnabled
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
        // Shown straight away after a relaunch; dropped once this copy is that version or newer.
        if let data = defaults.data(forKey: Key.latest),
           let release = try? JSONDecoder().decode(ReleaseInfo.self, from: data) {
            available = isNewer(release) ? release : nil
        }
    }

    /// Checks when due, then every hour looks again whether a day has passed.
    public func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    public func checkIfDue() async {
        guard isEnabled() else { return }
        if let lastCheck, now().timeIntervalSince(lastCheck) < Self.interval { return }
        await checkNow()
    }

    public func checkNow() async {
        // Without a version (tests, `swift run`) there is nothing to compare against.
        guard currentVersion != nil, status != .checking else { return }
        status = .checking
        do {
            let release = try await fetch()
            available = isNewer(release) ? release : nil
            status = available == nil ? .upToDate : .idle
            if let data = try? JSONEncoder().encode(release) { defaults.set(data, forKey: Key.latest) }
        } catch {
            // Offline or rate-limited: try again at the next due check, keep what is known.
            status = .failed
        }
        let checked = now()
        lastCheck = checked
        defaults.set(checked, forKey: Key.lastCheck)
    }

    /// Called when the user turns checking off: the banner should not linger.
    public func clearAvailable() {
        available = nil
    }

    private func isNewer(_ release: ReleaseInfo) -> Bool {
        guard let currentVersion else { return false }
        return ReleaseVersion.isNewer(release.version, than: currentVersion) ?? false
    }
}
