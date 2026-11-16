import SwiftUI
import MemorySaverCore

/// Help button that explains what each icon means, shown in a popover.
struct IconLegendButton: View {
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: { Image(systemName: "questionmark.circle") }
            .help(tr(.legendButtonHelp)).accessibilityLabel(tr(.legendButtonAccessibilityLabel))
            .popover(isPresented: $isShown, arrowEdge: .top) { IconLegend() }
    }
}

struct IconLegend: View {
    var version: String? = AppVersion.current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(tr(.legendSectionMenuBar)) {
                row(tr(.legendMenuBarNormal)) {
                    MenuBarIcon(pressure: .normal, hasRecommendations: false)
                }
                row(tr(.legendMenuBarRecommendation)) {
                    MenuBarIcon(pressure: .normal, hasRecommendations: true)
                }
                row(tr(.legendMenuBarWarning)) {
                    MenuBarIcon(pressure: .warning, hasRecommendations: false)
                }
                row(tr(.legendMenuBarCritical)) {
                    MenuBarIcon(pressure: .critical, hasRecommendations: false)
                }
            }
            Divider()
            section(tr(.legendSectionWindow)) {
                row(tr(.legendWindowExpand)) { Image(systemName: "chevron.right") }
                row(tr(.legendWindowRefresh)) { Image(systemName: "arrow.clockwise") }
                row(tr(.legendWindowSettings)) { Image(systemName: "gearshape") }
                row(tr(.legendWindowQuit)) { Image(systemName: "power") }
            }
            Divider()
            section(tr(.legendSectionGrowth)) {
                note(tr(.legendGrowthNote))
            }
            if let version {
                Divider()
                Text(tr(.legendVersion, version))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            rows()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ text: String, @ViewBuilder icon: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon().frame(width: 22)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
