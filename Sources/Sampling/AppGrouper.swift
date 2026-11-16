import Foundation
import MemorySaverCore

/// Folds helper processes into their app. Only top-level `.app` bundles are owners. A process
/// is attributed, in order, to: itself if it is an owner; its responsible process if that is an
/// owner; the nearest owner up its parent chain; the owner whose bundle contains its executable
/// (not for bundles under /System/, where unrelated processes share framework paths).
public struct AppGrouper: AppGrouping {
    public init() {}

    public func group(processes: [ProcessSample], apps: [RunningAppInfo]) -> [AppMemoryUsage] {
        let owners = apps.filter { $0.bundleURL.map(Self.isTopLevelApp) ?? false }
        let ownersByPID = Dictionary(owners.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let parentByPID = Dictionary(
            processes.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        // "/Applications/Foo.app/" with the trailing slash so "Foo.app" does not match "Foo.appx".
        let bundlePrefixes: [(prefix: String, pid: Int32)] = owners.compactMap { app in
            guard let url = app.bundleURL else { return nil }
            let path = url.standardizedFileURL.path
            guard !path.hasPrefix("/System/") else { return nil }
            return (path.hasSuffix("/") ? path : path + "/", app.pid)
        }

        func owner(of process: ProcessSample) -> Int32? {
            if ownersByPID[process.pid] != nil { return process.pid }
            if let responsible = process.responsiblePID, ownersByPID[responsible] != nil {
                return responsible
            }
            var pid = process.pid
            var visited: Set<Int32> = []
            while visited.insert(pid).inserted {
                if ownersByPID[pid] != nil { return pid }
                guard let parent = parentByPID[pid], parent > 0 else { break }
                pid = parent
            }
            guard let path = process.executablePath else { return nil }
            return bundlePrefixes
                .filter { path.hasPrefix($0.prefix) }
                .max { $0.prefix.count < $1.prefix.count }?
                .pid
        }

        var processesByApp: [Int32: [ProcessSample]] = [:]
        for process in processes {
            if let appPID = owner(of: process) {
                processesByApp[appPID, default: []].append(process)
            }
        }

        return processesByApp.compactMap { appPID, members -> AppMemoryUsage? in
            guard let app = ownersByPID[appPID] else { return nil }
            let main = members.first { $0.pid == appPID }
            let helpers = members
                .filter { $0.pid != appPID }
                .sorted { ($0.footprintBytes, $1.pid) > ($1.footprintBytes, $0.pid) }
            let ordered = (main.map { [$0] } ?? []) + helpers
            let id = app.bundleIdentifier
                ?? main?.executablePath
                ?? app.displayName
            return AppMemoryUsage(
                id: id,
                displayName: app.displayName,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                mainPID: appPID,
                footprintBytes: ordered.reduce(0) { $0 + $1.footprintBytes },
                launchDate: app.launchDate ?? main?.startTime,
                processes: ordered,
                canRelaunch: app.bundleURL.map(Self.canRelaunch) ?? false
            )
        }
        .sorted { ($0.footprintBytes, $1.id) > ($1.footprintBytes, $0.id) }
    }

    private static let bundleExtensions: Set<String> = ["app", "framework", "xpc", "appex", "bundle"]

    /// A `.app` bundle that is not nested inside another bundle. XPC services, extensions,
    /// plug-ins and helper apps inside an app are not.
    static func isTopLevelApp(_ bundleURL: URL) -> Bool {
        let components = bundleURL.standardizedFileURL.pathComponents
        guard let last = components.last, (last as NSString).pathExtension.lowercased() == "app" else {
            return false
        }
        return !components.dropLast().contains {
            bundleExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    /// Apps under /System/Library/ (Finder, Dock, loginwindow, Control Center...) are kept
    /// alive by launchd; quitting them is not a relaunch the user asked for.
    static func canRelaunch(_ bundleURL: URL) -> Bool {
        !bundleURL.standardizedFileURL.path.hasPrefix("/System/Library/")
    }
}
