import Foundation
import MemorySaverCore
import Testing
@testable import Sampling

private func proc(
    _ pid: Int32, parent: Int32 = 1, responsible: Int32? = nil, footprint: UInt64,
    path: String? = nil, start: Date? = nil
) -> ProcessSample {
    ProcessSample(
        pid: pid, parentPID: parent, name: "p\(pid)", executablePath: path,
        footprintBytes: footprint, startTime: start, responsiblePID: responsible)
}

/// Defaults to a top-level app bundle so the app is an owner.
private func app(
    _ pid: Int32, id: String? = nil, name: String = "App", bundle: String? = "",
    launch: Date? = nil
) -> RunningAppInfo {
    let path = bundle == "" ? "/Applications/App\(pid).app" : bundle
    return RunningAppInfo(
        pid: pid, bundleIdentifier: id, displayName: name,
        bundleURL: path.map { URL(fileURLWithPath: $0) }, launchDate: launch)
}

struct AppGrouperTests {
    let grouper = AppGrouper()

    @Test func foldsChildrenByParentChain() {
        let processes = [
            proc(100, footprint: 10),
            proc(101, parent: 100, footprint: 5),
            proc(102, parent: 101, footprint: 30),  // grandchild
        ]
        let result = grouper.group(processes: processes, apps: [app(100, id: "com.a")])
        #expect(result.count == 1)
        #expect(result[0].footprintBytes == 45)
        #expect(result[0].mainPID == 100)
        // Main first, then helpers by footprint descending.
        #expect(result[0].processes.map(\.pid) == [100, 102, 101])
    }

    @Test func fallsBackToBundlePath() {
        let processes = [
            proc(200, footprint: 10, path: "/Applications/Brave.app/Contents/MacOS/Brave"),
            proc(300, parent: 1, footprint: 50,
                 path: "/Applications/Brave.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
        ]
        let result = grouper.group(
            processes: processes, apps: [app(200, id: "com.brave", bundle: "/Applications/Brave.app")])
        #expect(result.count == 1)
        #expect(result[0].footprintBytes == 60)
        #expect(result[0].processes.map(\.pid) == [200, 300])
    }

    /// The nested helper app is listed as a running application but is not an owner; its
    /// processes go to the outer app.
    @Test func nestedHelperAppIsNotAnOwner() {
        let processes = [
            proc(10, footprint: 1),
            proc(11, parent: 1, footprint: 2),
            proc(400, parent: 1, footprint: 7, path: "/Applications/Outer.app/Contents/Inner.app/Contents/XPC/svc"),
        ]
        let apps = [
            app(10, id: "outer", bundle: "/Applications/Outer.app"),
            app(11, id: "inner", bundle: "/Applications/Outer.app/Contents/Inner.app"),
        ]
        let result = grouper.group(processes: processes, apps: apps)
        #expect(result.map(\.id) == ["outer"])
        #expect(result[0].processes.map(\.pid) == [10, 400])
    }

    @Test func bundlePrefixRequiresPathBoundary() {
        let processes = [proc(500, footprint: 1, path: "/Applications/Foo.appendix/bin")]
        let result = grouper.group(
            processes: processes, apps: [app(10, id: "foo", bundle: "/Applications/Foo.app")])
        #expect(result.isEmpty)
    }

    @Test func survivesParentCycle() {
        let processes = [
            proc(600, parent: 601, footprint: 1),
            proc(601, parent: 600, footprint: 1),
            proc(602, parent: 602, footprint: 1),
        ]
        let result = grouper.group(processes: processes, apps: [app(10, id: "x")])
        #expect(result.isEmpty)
    }

    @Test func cycleStillUsesPathFallback() {
        let processes = [
            proc(600, parent: 601, footprint: 3, path: "/Applications/X.app/Contents/MacOS/h"),
            proc(601, parent: 600, footprint: 4),
        ]
        let result = grouper.group(
            processes: processes, apps: [app(10, id: "x", bundle: "/Applications/X.app")])
        #expect(result.count == 1)
        #expect(result[0].footprintBytes == 3)
    }

    @Test func dropsUnownedProcesses() {
        let processes = [
            proc(100, footprint: 10),
            proc(700, parent: 1, footprint: 999, path: "/usr/libexec/something"),
            proc(701, parent: 700, footprint: 999),
        ]
        let result = grouper.group(processes: processes, apps: [app(100, id: "com.a")])
        #expect(result.map(\.footprintBytes) == [10])
    }

    @Test func sortsByFootprintDescending() {
        let processes = [
            proc(1000, footprint: 5),
            proc(2000, footprint: 50),
            proc(3000, footprint: 20),
            proc(3001, parent: 3000, footprint: 40),
        ]
        let apps = [app(1000, id: "small"), app(2000, id: "big"), app(3000, id: "mid")]
        let result = grouper.group(processes: processes, apps: apps)
        #expect(result.map(\.id) == ["mid", "big", "small"])
    }

    @Test func idFallsBackToExecutablePathThenName() {
        let processes = [
            proc(1, footprint: 1, path: "/Applications/Tool.app/Contents/MacOS/tool"),
            proc(2, footprint: 2),
        ]
        let apps = [app(1, name: "Tool"), app(2, name: "Nameless")]
        let result = grouper.group(processes: processes, apps: apps)
        #expect(result.map(\.id) == ["Nameless", "/Applications/Tool.app/Contents/MacOS/tool"])
        #expect(result.allSatisfy { $0.bundleIdentifier == nil })
    }

    @Test func fillsMetadata() {
        let launch = Date(timeIntervalSince1970: 1_000)
        let start = Date(timeIntervalSince1970: 2_000)
        let bundle = "/Applications/A.app"
        let r1 = grouper.group(
            processes: [proc(5, footprint: 1, start: start)],
            apps: [app(5, id: "a", name: "A", bundle: bundle, launch: launch)])
        #expect(r1.first?.launchDate == launch)
        #expect(r1.first?.displayName == "A")
        #expect(r1.first?.bundleURL == URL(fileURLWithPath: bundle))
        #expect(r1.first?.canRelaunch == true)

        // Without an NSWorkspace launch date, the main process start time is used.
        let r2 = grouper.group(processes: [proc(5, footprint: 1, start: start)], apps: [app(5, id: "a")])
        #expect(r2.first?.launchDate == start)
    }

    @Test func appWithoutReadableMainProcessKeepsHelpers() {
        let processes = [proc(900, parent: 50, footprint: 8)]
        let result = grouper.group(processes: processes, apps: [app(50, id: "a")])
        #expect(result.first?.mainPID == 50)
        #expect(result.first?.processes.map(\.pid) == [900])
    }

    // MARK: Owners

    @Test(arguments: [
        ("/Applications/Brave Browser.app", true),
        ("/Applications/Utilities/Terminal.app", true),
        ("/System/Applications/Mail.app", true),
        ("/System/Library/CoreServices/Dock.app", true),
        ("/Applications/Brave Browser.app/", true),
        ("/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper.app", false),
        ("/Applications/Slack.app/Contents/Frameworks/Slack Helper.app", false),
        ("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc", false),
        ("/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle", false),
        ("/Applications/Foo.app/Contents/PlugIns/Widget.appex", false),
        ("/Library/Bundles/Thing.bundle/Contents/Resources/Agent.app", false),
        ("/usr/libexec/something", false),
        ("/Applications/Foo.appendix", false),
    ])
    func ownerTest(path: String, expected: Bool) {
        #expect(AppGrouper.isTopLevelApp(URL(fileURLWithPath: path)) == expected)
    }

    @Test func nonAppRunningApplicationsAreNotOwners() {
        let processes = [
            proc(10, footprint: 1),
            proc(20, footprint: 2),
            proc(21, parent: 20, footprint: 3),
            proc(30, footprint: 4),
            proc(40, footprint: 5),
        ]
        let apps = [
            app(10, id: "real"),
            app(20, id: "com.apple.WebKit.GPU", bundle:
                "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc"),
            app(30, id: "coreautha", bundle:
                "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle"),
            app(40, id: "nobundle", bundle: nil),
        ]
        let result = grouper.group(processes: processes, apps: apps)
        #expect(result.map(\.id) == ["real"])
    }

    @Test(arguments: [
        ("/Applications/Brave Browser.app", true),
        ("/Applications/Utilities/Terminal.app", true),
        ("/System/Applications/Mail.app", true),
        ("/System/Applications/Reminders.app", true),
        ("/Users/me/Applications/MenuTool.app", true),
        ("/System/Library/CoreServices/Finder.app", false),
        ("/System/Library/CoreServices/Dock.app", false),
        ("/System/Library/CoreServices/loginwindow.app", false),
        ("/System/Library/CoreServices/ControlCenter.app", false),
        ("/System/Library/CoreServices/NotificationCenter.app", false),
    ])
    func canRelaunchRule(path: String, expected: Bool) {
        let result = grouper.group(
            processes: [proc(7, footprint: 1)],
            apps: [app(7, id: "x", bundle: path)])
        #expect(result.first?.canRelaunch == expected)
    }

    // MARK: Attribution order

    @Test func responsiblePIDBeatsParentChain() throws {
        let processes = [
            proc(10, footprint: 1),
            proc(20, footprint: 1),
            proc(30, parent: 10, responsible: 20, footprint: 9),
        ]
        let result = grouper.group(processes: processes, apps: [app(10, id: "a"), app(20, id: "b")])
        let b = try #require(result.first { $0.id == "b" })
        #expect(b.processes.map(\.pid) == [20, 30])
    }

    @Test func ownerIsAlwaysItsOwnGroup() {
        // An app launched from another app (e.g. from Terminal) is still its own app.
        let processes = [proc(10, footprint: 1), proc(20, parent: 10, responsible: 10, footprint: 2)]
        let result = grouper.group(processes: processes, apps: [app(10, id: "a"), app(20, id: "b")])
        #expect(Set(result.map(\.id)) == ["a", "b"])
    }

    @Test func nonOwnerResponsiblePIDFallsThrough() {
        let processes = [
            proc(10, footprint: 1),
            proc(50, footprint: 1),  // launchd-managed daemon, not an app
            proc(30, parent: 10, responsible: 50, footprint: 9),
            proc(31, parent: 1, responsible: 31, footprint: 4,
                 path: "/Applications/App10.app/Contents/XPCServices/S.xpc/Contents/MacOS/S"),
        ]
        let result = grouper.group(processes: processes, apps: [app(10, id: "a")])
        #expect(result.first?.processes.map(\.pid) == [10, 30, 31])
    }

    @Test func noPathFallbackForSystemBundles() {
        let processes = [
            proc(10, footprint: 1),
            proc(11, parent: 1, footprint: 5, path: "/System/Applications/Mail.app/Contents/MacOS/helper"),
            proc(12, parent: 1, footprint: 6,
                 path: "/System/Library/CoreServices/Finder.app/Contents/XPCServices/X.xpc/Contents/MacOS/X"),
        ]
        let apps = [
            app(10, id: "com.apple.mail", bundle: "/System/Applications/Mail.app"),
            app(20, id: "com.apple.finder", bundle: "/System/Library/CoreServices/Finder.app"),
        ]
        let result = grouper.group(processes: processes, apps: apps)
        #expect(result.map(\.id) == ["com.apple.mail"])
        #expect(result[0].processes.map(\.pid) == [10])
    }

    /// Safari page processes run from a system framework, are parented by launchd and are
    /// listed as running applications themselves; only the responsible pid ties them to Safari.
    @Test func safariWebContentGoesToSafari() {
        let webKit = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices"
        let processes = [
            proc(500, footprint: 300, path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            proc(501, parent: 1, responsible: 500, footprint: 800,
                 path: "\(webKit)/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"),
            proc(502, parent: 1, responsible: 500, footprint: 200,
                 path: "\(webKit)/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"),
            proc(503, parent: 1, responsible: 503, footprint: 50,
                 path: "\(webKit)/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"),
        ]
        let apps = [
            app(500, id: "com.apple.Safari", name: "Safari", bundle: "/Applications/Safari.app"),
            app(501, id: "com.apple.WebKit.WebContent", name: "Safari Web Content",
                bundle: "\(webKit)/com.apple.WebKit.WebContent.xpc"),
            app(502, id: "com.apple.WebKit.GPU", name: "Safari Graphics and Media",
                bundle: "\(webKit)/com.apple.WebKit.GPU.xpc"),
            app(503, id: "com.apple.WebKit.WebContent", name: "Other Web Content",
                bundle: "\(webKit)/com.apple.WebKit.WebContent.xpc"),
        ]
        let result = grouper.group(processes: processes, apps: apps)
        #expect(result.map(\.id) == ["com.apple.Safari"])
        #expect(result[0].processes.map(\.pid) == [500, 501, 502])
        #expect(result[0].footprintBytes == 1_300)
        #expect(result[0].canRelaunch)
    }
}
