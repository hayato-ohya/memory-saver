import AppKit
import SwiftUI
import MemorySaverCore

public struct PopoverView: View {
    let viewModel: MonitorViewModel
    @State private var pendingRelaunch: AppMemoryUsage?
    @State private var contentHeight: CGFloat = Self.maxContentHeight

    private static let maxContentHeight: CGFloat = 520

    public init(viewModel: MonitorViewModel) { self.viewModel = viewModel }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = viewModel.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SystemHeader(system: snapshot.system)
                        Divider()
                        WindowServerSection(viewModel: viewModel, snapshot: snapshot)
                        OrphanedRelaunchStatuses(viewModel: viewModel, snapshot: snapshot)
                        RecommendationsSection(viewModel: viewModel, pendingRelaunch: $pendingRelaunch)
                        RankingSection(viewModel: viewModel, snapshot: snapshot, pendingRelaunch: $pendingRelaunch)
                    }
                    .padding(.trailing, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                // A ScrollView has no height of its own in a menu bar window, so it takes its
                // content's height up to the cap.
                .frame(height: min(contentHeight, Self.maxContentHeight))
            } else if let error = viewModel.lastError {
                // Without this, a sampler or database that always fails would leave the
                // popover saying it is measuring, forever.
                ContentUnavailableView(
                    tr(.popoverUnavailableTitle), systemImage: "exclamationmark.triangle",
                    description: Text(error))
                    .frame(minHeight: 160)
            } else {
                ContentUnavailableView(
                    tr(.popoverMeasuringTitle), systemImage: "memorychip",
                    description: Text(tr(.popoverMeasuringDescription)))
                    .frame(height: 160)
            }
            if viewModel.snapshot != nil, let error = viewModel.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Footer(viewModel: viewModel)
        }
        .padding(14)
        .frame(width: 360)
        .confirmationDialog(
            pendingRelaunch.map { tr(.relaunchConfirmTitle, $0.displayName) } ?? "",
            isPresented: Binding(
                get: { pendingRelaunch != nil }, set: { if !$0 { pendingRelaunch = nil } }),
            titleVisibility: .visible,
            presenting: pendingRelaunch
        ) { app in
            Button(tr(.relaunchConfirmButton)) { viewModel.relaunch(app) }
            Button(tr(.relaunchConfirmCancel), role: .cancel) {}
        } message: { app in
            Text(tr(.relaunchConfirmMessage, app.displayName))
        }
    }
}

// MARK: - Header

private struct SystemHeader: View {
    let system: SystemMemorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr(.popoverHeaderMemory)).font(.headline)
                Spacer()
                Text(pressureLabel).font(.subheadline).foregroundStyle(pressureColor)
            }
            ProgressView(value: Double(system.usedBytes), total: Double(max(system.totalBytes, 1)))
                .tint(pressureColor)
            HStack {
                Text("\(ByteFormat.string(system.usedBytes)) / \(ByteFormat.string(system.totalBytes))")
                    .monospacedDigit()
                Spacer()
                if system.swapUsedBytes > 0 {
                    Text(tr(.popoverHeaderSwap, ByteFormat.string(system.swapUsedBytes)))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
    }

    private var pressureLabel: String {
        switch system.pressure {
        case .normal: tr(.popoverPressureNormal)
        case .warning: tr(.popoverPressureWarning)
        case .critical: tr(.popoverPressureCritical)
        }
    }

    private var pressureColor: Color {
        switch system.pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

// MARK: - WindowServer

private struct WindowServerSection: View {
    let viewModel: MonitorViewModel
    let snapshot: MemorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let bytes = snapshot.windowServerBytes {
                    let baseline = viewModel.windowServerBaseline
                    SizeRowLabels(
                        title: Text("WindowServer").font(.headline),
                        subtitle: nil, bytes: bytes, baseline: baseline, subject: .windowServer)
                } else {
                    Text("WindowServer").font(.headline)
                    Spacer()
                    Text(tr(.popoverWindowServerUnavailable)).foregroundStyle(.secondary)
                }
            }
            if let suspects {
                Text(tr(.popoverWindowServerSuspectsTitle))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(suspects) { suspect in
                    // Sorted by estimated window memory, so that figure is shown next to the count.
                    HStack {
                        Text(suspect.ownerName).lineLimit(1)
                        Spacer()
                        Text(tr(.popoverWindowServerWindowCount, suspect.windowCount)).foregroundStyle(.secondary)
                        Text(ByteFormat.string(suspect.estimatedBackingBytes)).monospacedDigit()
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                    .font(.subheadline)
                }
                Text(tr(.popoverWindowServerSuspectsNote))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var suspects: [WindowFootprint]? {
        for rec in viewModel.recommendations {
            if case .windowServerBloat(_, _, let suspects) = rec { return suspects }
        }
        return nil
    }
}

// MARK: - Recommendations

private struct RecommendationsSection: View {
    let viewModel: MonitorViewModel
    @Binding var pendingRelaunch: AppMemoryUsage?

    var body: some View {
        let items = viewModel.recommendations.compactMap { rec -> (AppMemoryUsage, Baseline)? in
            if case .relaunchApp(let app, let baseline) = rec { return (app, baseline) }
            return nil
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr(.popoverRecommendationsTitle)).font(.headline)
                ForEach(items, id: \.0.id) { app, baseline in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            AppIcon(url: app.bundleURL)
                            VStack(alignment: .leading) {
                                Text(app.displayName)
                                HStack(spacing: 6) {
                                    Text(ByteFormat.string(app.footprintBytes)).monospacedDigit()
                                    if let growth = ByteFormat.growth(of: app.footprintBytes, over: baseline.bytes) {
                                        Text(growth).monospacedDigit().foregroundStyle(.orange)
                                            .help(GrowthLabel.text(
                                                bytes: app.footprintBytes, baseline: baseline, subject: .app) ?? "")
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            RelaunchControl(
                                viewModel: viewModel, app: app, prominent: true,
                                pendingRelaunch: $pendingRelaunch)
                        }
                        RelaunchStatus(viewModel: viewModel, appID: app.id)
                    }
                }
            }
        }
    }
}

// MARK: - Ranking

private struct RankingSection: View {
    let viewModel: MonitorViewModel
    let snapshot: MemorySnapshot
    @Binding var pendingRelaunch: AppMemoryUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(.popoverRankingTitle)).font(.headline)
                Text(tr(.popoverRankingHint))
                    .font(.caption).foregroundStyle(.secondary)
            }
            let recommendedIDs = viewModel.recommendedAppIDs
            ForEach(snapshot.apps.prefix(10)) { app in
                let isExpanded = viewModel.expandedAppIDs.contains(app.id)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Button {
                            viewModel.toggleExpanded(app.id)
                        } label: {
                            AppRow(app: app, baseline: viewModel.appBaselines[app.id], isExpanded: isExpanded)
                        }
                        .buttonStyle(.plain)
                        .help(isExpanded
                            ? tr(.popoverRankingRowHelpHide)
                            : tr(.popoverRankingRowHelpShow))
                        .accessibilityHint(tr(.popoverRankingRowHint))
                        // Fixed width so the sizes line up whether or not a button is shown. The
                        // ZStack is what reserves the space: a frame on the control alone
                        // reserves nothing when the control renders no button.
                        ZStack(alignment: .trailing) {
                            RelaunchControl(
                                viewModel: viewModel, app: app, prominent: false,
                                pendingRelaunch: $pendingRelaunch)
                        }
                        .frame(width: 52, alignment: .trailing)
                    }
                    // The recommendation row above shows the status for recommended apps.
                    if !recommendedIDs.contains(app.id) {
                        RelaunchStatus(viewModel: viewModel, appID: app.id)
                    }
                    if isExpanded {
                        ProcessBreakdown(processes: app.processes)
                    }
                }
            }
        }
    }
}

private struct AppRow: View {
    let app: AppMemoryUsage
    let baseline: Baseline?
    let isExpanded: Bool

    var body: some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            AppIcon(url: app.bundleURL)
            SizeRowLabels(
                title: Text(app.displayName),
                subtitle: tr(.popoverRankingProcessCount, app.processes.count),
                bytes: app.footprintBytes, baseline: baseline, subject: .app)
        }
        // Without this, only the text and images are clickable, not the gaps between them.
        .contentShape(Rectangle())
    }
}

/// Title over a subtitle on the left; size over its growth on the right. The right column
/// holds only numbers so that it stays narrow and lines up between rows. What the growth is
/// measured from is explained in the icon legend and in the amount's tooltip.
private struct SizeRowLabels: View {
    let title: Text
    let subtitle: String?
    let bytes: UInt64
    let baseline: Baseline?
    let subject: GrowthLabel.Subject

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title.lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 0) {
            Text(ByteFormat.string(bytes)).monospacedDigit()
            if let baseline, let growth = ByteFormat.growth(of: bytes, over: baseline.bytes) {
                Text(growth).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .help(GrowthLabel.text(bytes: bytes, baseline: baseline, subject: subject) ?? "")
            }
        }
    }
}

private struct ProcessBreakdown: View {
    let processes: [ProcessSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(processes, id: \.pid) { process in
                HStack(spacing: 4) {
                    // The name gives way first, then the detail; the size never truncates.
                    Text(process.name).lineLimit(1).truncationMode(.middle)
                    if let detail = process.detail {
                        Text("— \(detail)").lineLimit(1).layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                    Text(ByteFormat.string(process.footprintBytes)).monospacedDigit()
                        .lineLimit(1).fixedSize().layoutPriority(2)
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.vertical, 4).padding(.leading, 46).padding(.trailing, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Shared pieces

private struct AppIcon: View {
    let url: URL?

    var body: some View {
        if let url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app").frame(width: 20, height: 20).foregroundStyle(.secondary)
        }
    }
}

private struct RelaunchControl: View {
    let viewModel: MonitorViewModel
    let app: AppMemoryUsage
    let prominent: Bool
    @Binding var pendingRelaunch: AppMemoryUsage?

    var body: some View {
        // System agents and apps without a bundle get no button at all.
        if AppRelauncher.canRelaunch(app) {
            let running = viewModel.relaunchStates[app.id] == .running
            let button = Button {
                pendingRelaunch = app
            } label: {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Text(tr(.relaunchButton))
                }
            }
            .disabled(running)
            if prominent {
                button.buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                button.buttonStyle(.bordered).controlSize(.mini)
            }
        }
    }
}

private struct RelaunchStatus: View {
    let viewModel: MonitorViewModel
    let appID: String
    var showsName = false

    var body: some View {
        switch viewModel.relaunchStates[appID] {
        case .running:
            VStack(alignment: .leading, spacing: 2) {
                Text(named(tr(.relaunchStatusWaiting)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr(.relaunchStatusStopWaiting)) { viewModel.stopWaiting(for: appID) }
                    .buttonStyle(.link)
                    .help(tr(.relaunchStatusStopWaitingHelp))
            }
            .font(.caption)
        case .finished(let result):
            if let message = RelaunchMessage.text(for: result) {
                HStack(alignment: .top) {
                    Text(named(message))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(tr(.relaunchStatusDismiss)) { viewModel.dismissRelaunchResult(for: appID) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        case nil:
            EmptyView()
        }
    }

    /// Puts the app's name in front of `message` for results shown away from the app's row.
    private func named(_ message: String) -> String {
        showsName ? tr(.relaunchStatusWithAppName, viewModel.relaunchNames[appID] ?? appID, message) : message
    }
}

/// Results for apps that are in neither the recommendations nor the ranking any more, e.g. an
/// app that quit and could not be reopened. Without this the message would vanish with the row.
private struct OrphanedRelaunchStatuses: View {
    let viewModel: MonitorViewModel
    let snapshot: MemorySnapshot

    var body: some View {
        let visible = Set(snapshot.apps.prefix(10).map(\.id)).union(viewModel.recommendedAppIDs)
        let orphans = viewModel.relaunchStates.keys.filter { !visible.contains($0) }.sorted()
        if !orphans.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(orphans, id: \.self) { id in
                    RelaunchStatus(viewModel: viewModel, appID: id, showsName: true)
                }
            }
        }
    }
}

enum RelaunchMessage {
    /// What to tell the user about a finished relaunch; nil when there is nothing to say.
    static func text(for result: RelaunchResult) -> String? {
        switch result {
        case .relaunched:
            nil
        case .notRunning:
            tr(.relaunchResultNotRunning)
        case .failed(let reason):
            tr(.relaunchResultFailed, reason)
        case .stoppedWaiting:
            tr(.relaunchResultStoppedWaiting)
        case .waitTimedOut:
            tr(.relaunchResultWaitTimedOut)
        case .quitButNotReopened(let reason):
            tr(.relaunchResultQuitButNotReopened, reason)
        }
    }
}

private struct Footer: View {
    let viewModel: MonitorViewModel

    var body: some View {
        HStack {
            if let date = viewModel.snapshot?.timestamp {
                Text(tr(.popoverFooterUpdated, date.formatted(date: .omitted, time: .standard)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            IconLegendButton()
            Button { viewModel.requestRefresh() } label: { Image(systemName: "arrow.clockwise") }
                .help(tr(.popoverFooterRefreshHelp)).accessibilityLabel(tr(.popoverFooterRefreshAccessibilityLabel))
            Button { viewModel.showSettings() } label: { Image(systemName: "gearshape") }
                .help(tr(.popoverFooterSettingsHelp)).accessibilityLabel(tr(.popoverFooterSettingsAccessibilityLabel))
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .help(tr(.popoverFooterQuitHelp)).accessibilityLabel(tr(.popoverFooterQuitAccessibilityLabel))
        }
        .buttonStyle(.borderless)
    }
}
