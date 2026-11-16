import CoreGraphics
import MemorySaverCore
import Testing
@testable import Sampling

struct WindowAggregationTests {
    let retina = DisplayInfo(bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isMain: true)
    let external = DisplayInfo(bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1, isMain: false)

    func window(_ pid: Int32, _ name: String = "App", _ rect: CGRect) -> WindowInfo {
        WindowInfo(pid: pid, ownerName: name, bounds: rect)
    }

    @Test func groupsByPIDAndSortsByBytes() {
        let windows = [
            window(1, "A", CGRect(x: 0, y: 0, width: 100, height: 100)),
            window(1, "A", CGRect(x: 0, y: 0, width: 100, height: 100)),
            window(2, "B", CGRect(x: 0, y: 0, width: 300, height: 100)),
        ]
        let result = aggregateWindows(windows, displays: [retina], excludingPIDs: [99])
        #expect(result.map(\.pid) == [2, 1])
        #expect(result[0] == WindowFootprint(pid: 2, ownerName: "B", windowCount: 1, estimatedBackingBytes: 300 * 100 * 4 * 4))
        #expect(result[1].windowCount == 2)
        #expect(result[1].estimatedBackingBytes == 2 * 100 * 100 * 4 * 4)
    }

    @Test func usesScaleOfDisplayWindowIsMostlyOn() {
        // 100 points on the retina display, 300 on the 1x external one.
        let windows = [window(1, "App", CGRect(x: 1412, y: 0, width: 400, height: 100))]
        let result = aggregateWindows(windows, displays: [retina, external], excludingPIDs: [99])
        #expect(result.first?.estimatedBackingBytes == 400 * 100 * 1 * 4)
    }

    @Test func offscreenWindowUsesMainDisplayScale() {
        let windows = [window(1, "App", CGRect(x: -10_000, y: -10_000, width: 10, height: 10))]
        let result = aggregateWindows(windows, displays: [external, retina], excludingPIDs: [99])
        #expect(result.first?.estimatedBackingBytes == 10 * 10 * 4 * 4)
    }

    @Test func skipsWindowServerOwnProcessAndBadSizes() {
        let windows = [
            window(10, "WindowServer", CGRect(x: 0, y: 0, width: 100, height: 100)),
            window(99, "Me", CGRect(x: 0, y: 0, width: 100, height: 100)),
            window(3, "Zero", CGRect(x: 0, y: 0, width: 0, height: 100)),
            window(4, "Huge", CGRect(x: 0, y: 0, width: 100_000, height: 100)),
            window(5, "Ok", CGRect(x: 0, y: 0, width: 1, height: 1)),
        ]
        let result = aggregateWindows(windows, displays: [retina], excludingPIDs: [99, 10])
        #expect(result.map(\.pid) == [5])
    }

    @Test func emptyInput() {
        #expect(aggregateWindows([], displays: [], excludingPIDs: [1]).isEmpty)
    }
}

/// WindowServer's own windows are reported under the owner name "Window Server" (with a
/// space), so they must be excluded by pid, not by name.
@Test func excludedPIDsAreDroppedWhateverTheOwnerName() {
    let screen = DisplayInfo(bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), scale: 1, isMain: true)
    let windows = [
        WindowInfo(pid: 405, ownerName: "Window Server", bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
        WindowInfo(pid: 7, ownerName: "Finder", bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
    ]
    let result = aggregateWindows(windows, displays: [screen], excludingPIDs: [405])
    #expect(result.map(\.pid) == [7])
}
