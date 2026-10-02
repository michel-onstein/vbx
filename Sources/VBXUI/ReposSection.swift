import VBXAppCore
import VBXCore
import SwiftUI

/// The sidebar's repository picker, shown only for a multi-repository
/// workspace.
///
/// A single-repository workspace has nothing to pick between, so the section
/// is absent rather than showing one inert row.
struct SidebarReposSection: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        if let reason = store.unavailableReason(.repos) {
            // Shown even though the workspace may hold one repository: which
            // it is, is exactly what the failed report would have said.
            Section("Repositories") {
                UnavailableReportLabel(report: .repos, reason: reason)
            }
        } else if store.repos.isWorkspace {
            Section("Repositories") {
                if !store.repoFilter.isEmpty {
                    Button {
                        store.repoFilter = []
                    } label: {
                        HStack {
                            Label("All repositories", systemImage: "square.stack.3d.up")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                ForEach(store.repos.repos) { repo in
                    row(repo)
                }

                if !store.repos.crossRepoEdges.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                        Text("\(store.repos.crossRepoEdges.count) cross-repo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .help("Dependencies that cross a repository boundary")
                }
            }
        }
    }

    private func row(_ repo: RepoInfo) -> some View {
        let isSelected = store.repoFilter.contains(repo.name)

        return Button {
            store.toggleRepo(repo.name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                Text(repo.name).lineLimit(1)
                Spacer()
                // A repository that failed to load is flagged, not hidden:
                // silently dropping it would make its beads look closed.
                if !repo.isHealthy {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(repo.error)
                }
                Text("\(repo.issueCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .help(repo.prefix.isEmpty ? repo.name : "\(repo.name) — ids start with \(repo.prefix)")
    }
}

/// The repository a bead belongs to, as a compact badge.
struct RepoBadge: View {
    let repo: RepoInfo
    var isCrossRepo = false

    var body: some View {
        HStack(spacing: 2) {
            if isCrossRepo {
                // The interesting beads in a multi-repo workspace are the ones
                // on a boundary-crossing edge — that is the coordination cost.
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 7))
            }
            Text(repo.badge)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
        .help(
            isCrossRepo
                ? "\(repo.name) — on a dependency that crosses repositories"
                : repo.name)
    }

    /// Colour derived from the name, so a repository looks the same
    /// everywhere without anyone configuring a palette.
    private var tint: Color {
        isCrossRepo ? .purple : Self.palette[abs(repo.name.hashValue) % Self.palette.count]
    }

    private static let palette: [Color] = [.blue, .teal, .indigo, .green, .brown, .cyan]
}
