import SwiftUI

struct SidebarSyncIndicator: View {
    let activity: MailSyncActivity
    @State private var didWaitForProgress = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if activity.isActive && (didWaitForProgress || isPaused) {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        if isPaused {
                            Image(systemName: "clock")
                        } else if reduceMotion {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Text(activity.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .lineLimit(1)
                    if let detail = activity.detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(activity.explanation)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Mail sync")
                .accessibilityValue(activity.explanation)
                .accessibilityIdentifier("sidebar.mailSync")
            }
        }
        .task(id: activity.isActive) {
            didWaitForProgress = false
            guard activity.isActive else { return }
            // Counts may change on every page. Delay the start of the entire
            // activity, so quick checks stay quiet and paging never restarts it.
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            didWaitForProgress = true
        }
    }

    private var isPaused: Bool {
        if case .waiting = activity { return true }
        return false
    }
}
