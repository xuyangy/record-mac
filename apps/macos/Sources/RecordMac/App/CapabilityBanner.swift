import SwiftUI

/// The reduced capabilities shown to the creator (FR-071). It shows the reductions of the latest
/// detection; dismissing hides only that report, and the next detection shows again every
/// reduction it still finds.
@MainActor
final class CapabilityBannerModel: ObservableObject {
    @Published private(set) var visibleReductions: [String] = []

    private let detect: @Sendable () -> [String]
    private var didStartAtLaunch = false
    private var latestRun = 0

    /// Detection at launch covers what is known before any capture or export format is chosen:
    /// display refresh rates and the Presenter Overlay branch. It probes no encoder; the formats
    /// a capture or export chooses are not detected here.
    init(detect: @escaping @Sendable () -> [String] = {
        CapabilityDetector().detect(formats: []).reductions
    }) {
        self.detect = detect
    }

    /// Runs the launch detection once, however often the caller asks.
    func detectAtLaunch() {
        guard !didStartAtLaunch else { return }
        didStartAtLaunch = true
        refresh()
    }

    /// Detects off the main actor. Only the latest run publishes, so a slower earlier run cannot
    /// replace a newer report.
    func refresh() {
        latestRun += 1
        let run = latestRun
        let detect = detect
        Task {
            let reductions = await Task.detached(priority: .utility) { detect() }.value
            self.publish(reductions, from: run)
        }
    }

    func publish(_ reductions: [String], from run: Int? = nil) {
        if let run, run != latestRun { return }
        visibleReductions = reductions
    }

    func dismiss() {
        visibleReductions = []
    }
}

/// One row per reduction. Long lists scroll within a bounded height so the controls below stay
/// reachable. With nothing to show it takes no space, its insets included.
struct CapabilityBanner: View {
    @ObservedObject var model: CapabilityBannerModel
    var insets = EdgeInsets()
    var maxHeight: CGFloat = 96

    var body: some View {
        if !model.visibleReductions.isEmpty {
            HStack(alignment: .top, spacing: Theme.space3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.statusWarning)
                    .font(.system(size: Theme.iconMd))
                    .accessibilityHidden(true)
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView(.vertical) { rows }
                }
                .frame(maxHeight: maxHeight)
                Button {
                    model.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Theme.iconSm, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.fgMuted)
                .accessibilityLabel("Dismiss reduced capability notices")
            }
            .padding(Theme.space3)
            .background(
                Theme.statusWarning.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .stroke(Theme.statusWarning.opacity(0.35), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Reduced capabilities")
            .padding(insets)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            ForEach(Array(model.visibleReductions.enumerated()), id: \.offset) { _, reduction in
                Text(reduction)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
