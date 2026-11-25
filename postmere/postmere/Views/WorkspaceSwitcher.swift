import SwiftUI

/// The current workspace, and a menu to move to another one the person belongs to.
/// Shows nothing for someone in a single workspace.
struct WorkspaceSwitcher: View {
    let session: BackendSession
    var font: Font = .system(size: 12, weight: .medium)

    var body: some View {
        Group {
            if session.workspaces.count > 1, let current = session.currentWorkspace {
                Menu {
                    Section("Switch workspace") {
                        ForEach(session.workspaces) { workspace in
                            Button {
                                guard workspace.id != current.id else { return }
                                Task { await session.switchWorkspace(to: workspace.id) }
                            } label: {
                                if workspace.id == current.id {
                                    Label("\(workspace.name) · \(workspace.roleTitle)", systemImage: "checkmark")
                                } else {
                                    Text("\(workspace.name) · \(workspace.roleTitle)")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        WorkspaceMonogram(name: current.name)
                        Text(current.name).lineLimit(1)
                        if session.isSwitchingWorkspace { ProgressView().controlSize(.mini) }
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(font)
                    .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(session.isBusy)
                .help("Switch workspace")
                .accessibilityLabel("Workspace, \(current.name)")
                .accessibilityHint("Switch to another workspace")
            }
        }
        .task(id: session.realtimeGeneration) { await session.refreshWorkspaces() }
        .animation(.smooth(duration: 0.25), value: session.workspaces)
    }
}

/// A workspace's first letter in a small rounded square.
struct WorkspaceMonogram: View {
    let name: String
    var size: CGFloat = 18
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.58, weight: .semibold, design: .serif))
            .foregroundStyle(palette.accentInk)
            .frame(width: size, height: size)
            .background(palette.accentInk.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}
