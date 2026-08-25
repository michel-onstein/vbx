import VBXAppCore
import VBXCore
import SwiftUI

/// Bead-to-commit correlation: what actually happened, and how sure the engine
/// is about each link.
///
/// bv splits this across several keys; here it is one surface with tabs, and
/// the timeline is drawn beside the table rather than toggled with it, so a
/// selected commit is visible in both at once.
struct HistoryView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var tab: Tab = .commits
    @State private var selectedCommit: String?
    /// The diff on screen — non-nil is what presents it. A companion flag
    /// would present the sheet from a body that had not yet seen the patch,
    /// which opens an empty window. See ``SidebarRecipesSection/editing``.
    @State private var patch: CommitPatch?
    @State private var causality: CausalityResult?
    @State private var filePath: String = ""
    @State private var fileBeads: FileBeadLookup?

    enum Tab: String, CaseIterable, Identifiable {
        case commits, timeline, files, hotspots, orphans
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .commits: "Commits"
            case .timeline: "Timeline"
            case .files: "Files"
            case .hotspots: "Hotspots"
            case .orphans: "Orphans"
            }
        }
    }

    var body: some View {
        Group {
            if let error = store.historyError {
                EmptyStateView(
                    symbol: "clock.badge.xmark",
                    title: "No history available",
                    message: error,
                    actionTitle: "Try Again",
                    action: { Task { await store.loadHistory(refresh: true) } }
                )
            } else if store.historyLoading {
                VStack(spacing: 8) {
                    ProgressView("Reading the object store…").controlSize(.large)
                    Text("The first read walks the commit history; later ones are cached.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !store.historyLoaded {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "History not loaded",
                    message: "Correlating beads with commits reads the repository's history.",
                    actionTitle: "Load History",
                    action: { Task { await store.loadHistory() } }
                )
            } else {
                content
            }
        }
        .task {
            // Idempotent, so re-entering the view costs nothing.
            await store.loadHistory()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .commits: commitsTab
            case .timeline: timelineTab
            case .files: filesTab
            case .hotspots: hotspotsTab
            case .orphans: orphansTab
            }
        }
        .sheet(item: $patch) { patchSheet($0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(.headline)
                Spacer()
                Text(store.history.gitRange)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                stat("commits", "\(store.history.stats.totalCommits)")
                stat("linked beads", "\(store.history.stats.beadsWithCommits)")
                stat("authors", "\(store.history.stats.uniqueAuthors)")
                stat("orphans", "\(store.orphans.stats.orphanCount)")
                if store.feedback.stats.totalFeedback > 0 {
                    stat(
                        "reviewed",
                        "\(store.feedback.stats.totalFeedback)")
                }
                Spacer()
                Button {
                    Task { await store.loadHistory(refresh: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Walk the history again")
            }

            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
    }

    private func stat(_ name: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.callout.monospacedDigit().weight(.medium))
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Commits

    /// Every linked commit with its bead, newest first.
    private var links: [(bead: String, commit: CorrelatedCommit)] {
        store.history.allCommits
    }

    private var commitsTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if links.isEmpty {
                    Text("No commit was attributed to any bead.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(20)
                }
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    commitRow(bead: link.bead, commit: link.commit)
                    Divider()
                }
            }
        }
    }

    private func commitRow(bead: String, commit: CorrelatedCommit) -> some View {
        let verdict = store.feedback.verdict(sha: commit.sha, beadID: bead)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(commit.shortSHA)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(commit.subject)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 12)
                ConfidenceBadge(commit: commit, confirmed: verdict?.type == "confirm")
            }

            HStack(spacing: 8) {
                Button {
                    store.select(id: bead)
                } label: {
                    Text(bead).font(.caption.monospaced())
                }
                .buttonStyle(.link)

                Label(commit.method.displayName, systemImage: commit.method.symbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let date = commit.timestamp {
                    Text(date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(commit.author).font(.caption2).foregroundStyle(.tertiary)

                Spacer()

                if !commit.files.isEmpty {
                    Button {
                        Task { await showPatch(sha: commit.sha) }
                    } label: {
                        Label("\(commit.files.count) files", systemImage: "doc.text.magnifyingglass")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Show the diff")
                }

                feedbackControls(bead: bead, commit: commit, verdict: verdict)
            }

            if !commit.reason.isEmpty {
                Text(commit.reason).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selectedCommit == commit.sha ? Color.accentColor.opacity(0.1) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedCommit = commit.sha }
    }

    /// Confirm and reject, which feed back into the engine's confidence.
    @ViewBuilder
    private func feedbackControls(
        bead: String, commit: CorrelatedCommit, verdict: CorrelationFeedback?
    ) -> some View {
        if let verdict {
            Label(
                verdict.type == "confirm" ? "Confirmed" : "Rejected",
                systemImage: verdict.type == "confirm" ? "checkmark.seal.fill" : "xmark.seal.fill"
            )
            .font(.caption2)
            .foregroundStyle(verdict.type == "confirm" ? .green : .red)
        } else {
            HStack(spacing: 2) {
                Button {
                    Task {
                        await store.recordCorrelation(
                            sha: commit.sha, beadID: bead, confirmed: true)
                    }
                } label: {
                    Image(systemName: "hand.thumbsup")
                }
                .help("This link is right — raise its confidence")

                Button {
                    Task {
                        await store.recordCorrelation(
                            sha: commit.sha, beadID: bead, confirmed: false)
                    }
                } label: {
                    Image(systemName: "hand.thumbsdown")
                }
                .help("This link is wrong — remove it")
            }
            .font(.caption2)
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Timeline

    private var timelineTab: some View {
        VStack(spacing: 0) {
            if let issue = store.selectedIssue {
                TimelineCanvas(
                    history: store.history.histories[issue.id],
                    causality: causality,
                    selectedCommit: $selectedCommit
                )
                .frame(minHeight: 180)
                .padding(12)
                Divider()
                causalityPanel
            } else {
                EmptyStateView(
                    symbol: "calendar.day.timeline.left",
                    title: "No bead selected",
                    message: "Select a bead to see its timeline and causal chain."
                )
            }
        }
        .task(id: store.focusedID) {
            guard let id = store.focusedID else { return }
            causality = await store.causality(for: id)
        }
    }

    @ViewBuilder
    private var causalityPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let insights = causality?.insights {
                    Text(insights.summary).font(.callout)
                    HStack(spacing: 14) {
                        stat("commits", "\(insights.commitCount)")
                        stat("blocked", String(format: "%.0f%%", insights.blockedPercentage))
                        if let total = CycleTime.describe(insights.totalDuration) {
                            stat("elapsed", total)
                        }
                    }
                    ForEach(insights.recommendations, id: \.self) { recommendation in
                        Label(recommendation, systemImage: "lightbulb")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let events = causality?.chain?.events, !events.isEmpty {
                    Text("Causal chain").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(events) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: event.type.symbolName)
                                .font(.caption2)
                                .foregroundStyle(event.type.isWaiting ? .red : .secondary)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.description).font(.caption)
                                if let blocker = event.blockerID {
                                    Button {
                                        store.select(id: blocker)
                                    } label: {
                                        Text(blocker).font(.caption2.monospaced())
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                            Spacer()
                            if let gap = CycleTime.describe(event.durationNext) {
                                Text("+\(gap)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    // MARK: - Files

    private var filesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Path in the repository", text: $filePath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { fileBeads = await store.beads(touching: filePath) } }
                Button("Look up") {
                    Task { fileBeads = await store.beads(touching: filePath) }
                }
                .disabled(filePath.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            if let lookup = fileBeads {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(lookup.totalBeads) beads touched \(lookup.filePath)")
                            .font(.callout.weight(.medium))
                        beadReferences("Open", lookup.openBeads, tint: .blue)
                        beadReferences("Closed", lookup.closedBeads, tint: .green)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            } else {
                Text("Enter a repository-relative path to see which beads touched it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func beadReferences(_ title: String, _ beads: [BeadReference], tint: Color)
        -> some View
    {
        if !beads.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(beads) { reference in
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Button {
                        store.select(id: reference.beadID)
                    } label: {
                        Text(reference.beadID).font(.caption.monospaced())
                    }
                    .buttonStyle(.link)
                    Text(reference.title).font(.caption).lineLimit(1)
                    Spacer()
                    Text("\(reference.totalChanges) changes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let sha = reference.commitSHAs.first {
                        Button {
                            Task { await showPatch(sha: sha, path: fileBeads?.filePath) }
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Show the diff for this file")
                    }
                }
            }
        }
    }

    // MARK: - Hotspots

    private var hotspotsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "\(store.hotspots.stats.totalFiles) files, "
                        + "\(store.hotspots.stats.filesWithMultipleBeads) touched by more than one bead"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(store.hotspots.hotspots) { hotspot in
                    HStack(spacing: 8) {
                        Text(hotspot.filePath).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        Text("\(hotspot.openBeads) open")
                            .font(.caption2)
                            .foregroundStyle(hotspot.openBeads > 0 ? Color.blue : Color.secondary)
                        Text("\(hotspot.totalBeads) total")
                            .font(.caption2.monospacedDigit())
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        filePath = hotspot.filePath
                        tab = .files
                        Task { fileBeads = await store.beads(touching: hotspot.filePath) }
                    }
                    Divider()
                }
            }
            .padding(12)
        }
    }

    // MARK: - Orphans

    private var orphansTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "\(store.orphans.stats.orphanCount) of "
                        + "\(store.orphans.stats.totalCommits) commits belong to no bead."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(store.orphans.candidates) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(candidate.shortSHA)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(candidate.subject).font(.callout).lineLimit(1)
                            Spacer()
                            SuspicionBadge(score: candidate.suspicionScore)
                        }
                        HStack(spacing: 8) {
                            Text(candidate.author).font(.caption2).foregroundStyle(.tertiary)
                            ForEach(candidate.signals) { signal in
                                Text("\(signal.signal) +\(signal.weight)")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .background(.quaternary, in: Capsule())
                            }
                            Spacer()
                            Button {
                                Task { await showPatch(sha: candidate.sha) }
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                        }
                        ForEach(candidate.probableBeads) { probable in
                            HStack(spacing: 6) {
                                Text("maybe").font(.caption2).foregroundStyle(.tertiary)
                                Button {
                                    store.select(id: probable.beadID)
                                } label: {
                                    Text(probable.beadID).font(.caption2.monospaced())
                                }
                                .buttonStyle(.link)
                                Text(probable.reasons.joined(separator: "; "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
            .padding(12)
        }
    }

    // MARK: - Patch sheet

    private func showPatch(sha: String, path: String? = nil) async {
        patch = await store.patch(sha: sha, path: path)
    }

    private func patchSheet(_ patch: CommitPatch) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(patch.sha.prefix(7)).font(.headline.monospaced())
                if !patch.path.isEmpty {
                    Text(patch.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { self.patch = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(patch.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(colour(for: line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line.kind))
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 760, height: 560)
    }

    private func colour(for kind: PatchLine.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .hunk: .purple
        case .meta: .secondary
        case .context: .primary
        }
    }

    private func background(for kind: PatchLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.08)
        case .removed: .red.opacity(0.08)
        default: .clear
        }
    }
}

/// The engine's confidence in one link, as a badge.
///
/// The percentage is shown rather than only a band, because "high" covers
/// 0.75 to 0.90 and the difference matters when reviewing a link.
struct ConfidenceBadge: View {
    let commit: CorrelatedCommit
    var confirmed = false

    var body: some View {
        HStack(spacing: 3) {
            if confirmed {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 8))
            }
            Text(commit.confidencePercent).font(.caption2.monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(tint.opacity(0.14), in: Capsule())
        .help("\(commit.confidenceLevel) — \(commit.method.displayName)")
    }

    private var tint: Color {
        switch commit.confidence {
        case 0.9...: .green
        case 0.75..<0.9: .teal
        case 0.5..<0.75: .orange
        default: .red
        }
    }
}

/// How suspicious an unattributed commit is.
struct SuspicionBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
            .help(
                score == 0
                    ? "No bead resembles this commit"
                    : "Suspicion \(score)/100 that this belongs to a bead")
    }

    private var tint: Color {
        switch score {
        case 70...: .red
        case 40..<70: .orange
        case 1..<40: .yellow
        default: .secondary
        }
    }
}

/// One bead's lifecycle drawn on a time axis.
///
/// Drawn on a `Canvas` rather than assembled from views: a long history is
/// hundreds of marks, and the axis needs continuous positioning rather than
/// stacked layout.
struct TimelineCanvas: View {
    let history: BeadHistory?
    let causality: CausalityResult?
    @Binding var selectedCommit: String?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let history, let span = span(history) else {
                    let text = Text("No dated activity for this bead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return
                }

                let inset: CGFloat = 18
                let width = max(size.width - inset * 2, 1)
                let axisY = size.height / 2

                // Blocked stretches first, so the marks draw on top of them.
                for period in causality?.insights?.blockedPeriods ?? [] {
                    guard let start = period.startTime, let end = period.endTime else { continue }
                    let x1 = inset + width * fraction(start, in: span)
                    let x2 = inset + width * fraction(end, in: span)
                    let rect = CGRect(x: x1, y: axisY - 9, width: max(x2 - x1, 2), height: 18)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.red.opacity(0.18)))
                }

                var axis = Path()
                axis.move(to: CGPoint(x: inset, y: axisY))
                axis.addLine(to: CGPoint(x: inset + width, y: axisY))
                context.stroke(axis, with: .color(.secondary.opacity(0.4)), lineWidth: 1)

                // Commits below the axis.
                for commit in history.commits {
                    guard let when = commit.timestamp else { continue }
                    let x = inset + width * fraction(when, in: span)
                    let isSelected = commit.sha == selectedCommit
                    let radius: CGFloat = isSelected ? 5 : 3
                    let dot = Path(
                        ellipseIn: CGRect(
                            x: x - radius, y: axisY + 6, width: radius * 2, height: radius * 2))
                    // Opacity carries confidence, so a weak link looks weak.
                    context.fill(
                        dot,
                        with: .color(.accentColor.opacity(0.35 + 0.65 * commit.confidence)))
                }

                // Lifecycle events above it.
                for event in history.events {
                    guard let when = event.timestamp else { continue }
                    let x = inset + width * fraction(when, in: span)
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: axisY - 4))
                    tick.addLine(to: CGPoint(x: x, y: axisY - 16))
                    context.stroke(tick, with: .color(colour(event.eventType)), lineWidth: 2)

                    let label = Text(event.eventType.displayName)
                        .font(.system(size: 8))
                        .foregroundStyle(colour(event.eventType))
                    context.draw(label, at: CGPoint(x: x, y: axisY - 24))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    /// The window the timeline covers, or nil when nothing is dated.
    private func span(_ history: BeadHistory) -> ClosedRange<Date>? {
        var dates = history.events.compactMap(\.timestamp)
        dates.append(contentsOf: history.commits.compactMap(\.timestamp))
        guard let first = dates.min(), let last = dates.max() else { return nil }
        // A single-instant history would divide by zero; widen it to an hour
        // so the mark lands in the middle rather than at the edge.
        if first == last {
            return first.addingTimeInterval(-1800)...last.addingTimeInterval(1800)
        }
        return first...last
    }

    private func fraction(_ date: Date, in span: ClosedRange<Date>) -> CGFloat {
        let total = span.upperBound.timeIntervalSince(span.lowerBound)
        guard total > 0 else { return 0.5 }
        let offset = date.timeIntervalSince(span.lowerBound)
        return CGFloat(min(max(offset / total, 0), 1))
    }

    private func colour(_ type: BeadEventType) -> Color {
        switch type {
        case .created: .blue
        case .claimed: .orange
        case .closed: .green
        case .reopened: .purple
        case .modified: .secondary
        case .unknown: .secondary
        }
    }
}
