import Charts
import SwiftUI
import MemorySaverCore

/// Reads a series' history; supplied by the app so the UI does not depend on the store.
public typealias HistoryLoader = @Sendable (SeriesKey, Date) async throws -> [TrendPoint]

enum HistoryRange: CaseIterable, Hashable {
    case day, week

    var duration: TimeInterval {
        switch self {
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        }
    }

    var label: String {
        switch self {
        case .day: tr(.chartRangeDay)
        case .week: tr(.chartRangeWeek)
        }
    }
}

/// One unbroken stretch of samples. A line is drawn within a segment, never across a gap.
struct HistorySegment: Identifiable, Equatable {
    var id: Int
    var points: [TrendPoint]
}

enum HistorySegments {
    /// Splits where consecutive samples are further apart than `maxGap`: the Mac was asleep,
    /// the app was not running, or MemorySaver was not. Joining across such a gap would draw
    /// a slope that was never measured.
    static func split(_ points: [TrendPoint], maxGap: TimeInterval) -> [HistorySegment] {
        var segments: [HistorySegment] = []
        var current: [TrendPoint] = []
        for point in points {
            if let last = current.last, point.timestamp.timeIntervalSince(last.timestamp) > maxGap {
                segments.append(HistorySegment(id: segments.count, points: current))
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { segments.append(HistorySegment(id: segments.count, points: current)) }
        return segments
    }

    /// Samples older than a day are kept every 15 minutes and WindowServer is sampled every 5,
    /// so a gap is anything clearly longer than the coarsest regular spacing.
    static let maxGap: TimeInterval = 20 * 60
}

/// Memory over time for one app or WindowServer, with its baseline as a dashed line.
struct HistoryChart: View {
    let series: SeriesKey
    let baseline: Baseline?
    let loader: HistoryLoader?
    /// Changes with every sample, so the chart follows the live numbers.
    let refreshToken: Date?
    /// Lines the chart up with the row's text.
    var leadingInset: CGFloat = 46

    @State private var range: HistoryRange
    @State private var segments: [HistorySegment]?

    init(
        series: SeriesKey, baseline: Baseline?, loader: HistoryLoader?, refreshToken: Date?,
        leadingInset: CGFloat = 46, range: HistoryRange = .day
    ) {
        self.series = series
        self.baseline = baseline
        self.loader = loader
        self.refreshToken = refreshToken
        self.leadingInset = leadingInset
        _range = State(initialValue: range)
    }

    private static let gigabyte = Double(1 << 30)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr(.chartTitle)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker(tr(.chartRangeAccessibilityLabel), selection: $range) {
                    ForEach(HistoryRange.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.mini).fixedSize()
            }
            content.frame(height: 90)
        }
        .padding(.vertical, 6).padding(.leading, leadingInset).padding(.trailing, 8)
        .task(id: TaskKey(range: range, token: refreshToken)) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let segments {
            if segments.reduce(0, { $0 + $1.points.count }) < 2 {
                Text(tr(.chartNotEnoughHistory))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart(segments)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func chart(_ segments: [HistorySegment]) -> some View {
        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        return Chart {
            ForEach(segments) { segment in
                ForEach(segment.points, id: \.timestamp) { point in
                    LineMark(
                        x: .value("time", point.timestamp),
                        y: .value("memory", Double(point.bytes) / Self.gigabyte),
                        series: .value("segment", segment.id))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .foregroundStyle(Color.accentColor)
                }
            }
            if let baseline {
                RuleMark(y: .value("baseline", Double(baseline.bytes) / Self.gigabyte))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.gray)
                    .annotation(position: .top, alignment: .leading, spacing: 1) {
                        Text(tr(.chartBaseline)).font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .day ? 4 : 7)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(timeLabel(date)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let gigabytes = value.as(Double.self) {
                        Text(Self.axisLabel(gigabytes: gigabytes))
                    }
                }
            }
        }
        .font(.caption2)
        .accessibilityLabel(tr(.chartTitle))
    }

    /// In the app's language, which can differ from the system's.
    private func timeLabel(_ date: Date) -> String {
        let locale = Locale(identifier: AppLanguage.current.identifier)
        return range == .day
            ? date.formatted(.dateTime.hour().locale(locale))
            : date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
    }

    /// "0 GB" rather than ByteCountFormatter's "Zero KB" at the bottom of the axis.
    static func axisLabel(gigabytes: Double) -> String {
        gigabytes <= 0 ? "0 GB" : ByteFormat.string(UInt64(gigabytes * gigabyte))
    }

    private func load() async {
        guard let loader else { segments = []; return }
        let since = Date().addingTimeInterval(-range.duration)
        let points = (try? await loader(series, since)) ?? []
        guard !Task.isCancelled else { return }
        segments = HistorySegments.split(points, maxGap: HistorySegments.maxGap)
    }

    private struct TaskKey: Equatable {
        var range: HistoryRange
        var token: Date?
    }
}
