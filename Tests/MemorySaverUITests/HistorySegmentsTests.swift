import Foundation
import Testing
import MemorySaverCore
@testable import MemorySaverUI

@Suite struct HistorySegmentsTests {
    private func points(_ minutes: [Double]) -> [TrendPoint] {
        minutes.map { TrendPoint(timestamp: Date(timeIntervalSince1970: $0 * 60), bytes: 1) }
    }

    @Test func regularSamplesStayInOneSegment() {
        let segments = HistorySegments.split(points([0, 1, 2, 7, 22]), maxGap: HistorySegments.maxGap)
        #expect(segments.map(\.points.count) == [5])
    }

    @Test func longGapStartsANewSegment() {
        let segments = HistorySegments.split(points([0, 1, 2, 60, 61, 200]), maxGap: HistorySegments.maxGap)
        #expect(segments.map(\.points.count) == [3, 2, 1])
        #expect(segments.map(\.id) == [0, 1, 2])
    }

    @Test func emptyInput() {
        #expect(HistorySegments.split([], maxGap: 60).isEmpty)
    }
}
