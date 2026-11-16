import SwiftUI
import MemorySaverCore

public struct MenuBarLabel: View {
    let viewModel: MonitorViewModel

    public init(viewModel: MonitorViewModel) { self.viewModel = viewModel }

    public var body: some View {
        MenuBarIcon(pressure: viewModel.pressure, hasRecommendations: !viewModel.recommendations.isEmpty)
            .accessibilityLabel(tr(.menuBarAccessibilityLabel))
    }
}

/// The menu bar symbol for one state. Shared with the icon legend so the two cannot drift apart.
struct MenuBarIcon: View {
    let pressure: MemoryPressureLevel
    let hasRecommendations: Bool

    var body: some View {
        // MenuBarExtra renders labels as template images, so a color only shows when the
        // symbol is rendered with a non-template palette.
        Image(systemName: hasRecommendations ? "memorychip.fill" : "memorychip")
            .symbolRenderingMode(tint == nil ? .monochrome : .palette)
            .foregroundStyle(tint ?? .primary, .primary)
            .overlay(alignment: .topTrailing) {
                if hasRecommendations {
                    Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 3, y: -2)
                }
            }
    }

    private var tint: Color? {
        switch pressure {
        case .normal: nil
        case .warning: .yellow
        case .critical: .red
        }
    }
}
