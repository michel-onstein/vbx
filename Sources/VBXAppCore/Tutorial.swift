import Foundation
import SwiftUI

/// One page of the tutorial.
public struct TutorialSection: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let summary: String
    /// The body, written as Markdown so it renders through the same component
    /// bead descriptions do — and so the table and code support already built
    /// gets used rather than duplicated.
    public let body: String
    /// The surface this section teaches, if it teaches one. Drives the
    /// "learn this view" link each surface shows.
    public let surface: ViewSurface?
    /// bv's key for the same thing, so someone arriving from the TUI can map
    /// what they already know onto this.
    public let terminalKey: String?

    // `body` comes last because it is a long multi-line literal; putting the
    // short metadata first keeps each section's declaration readable.
    public init(
        id: String, title: String, summary: String,
        surface: ViewSurface? = nil, terminalKey: String? = nil,
        body: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.body = body
        self.surface = surface
        self.terminalKey = terminalKey
    }
}

/// The tutorial's content and progress.
///
/// Progress is persisted so the tutorial can be left and resumed. It is keyed
/// by section id rather than by index: inserting a section in the middle
/// should not silently mark a different one as read.
@MainActor
public final class Tutorial: ObservableObject {
    @Published public private(set) var completed: Set<String> = []
    @Published public var selection: String?

    private let defaultsKey = "vbx.tutorial.completed"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: defaultsKey) ?? []
        // Sections that no longer exist are dropped on load, so a renamed
        // section cannot inflate the progress count forever.
        let known = Set(Self.sections.map(\.id))
        completed = Set(stored).intersection(known)
        selection = Self.sections.first(where: { !completed.contains($0.id) })?.id
            ?? Self.sections.first?.id
    }

    public var sections: [TutorialSection] { Self.sections }

    public func isComplete(_ id: String) -> Bool { completed.contains(id) }

    public func markComplete(_ id: String) {
        guard !completed.contains(id) else { return }
        completed.insert(id)
        persist()
    }

    public func markIncomplete(_ id: String) {
        guard completed.contains(id) else { return }
        completed.remove(id)
        persist()
    }

    public func reset() {
        completed = []
        persist()
        selection = Self.sections.first?.id
    }

    /// 0…1, for the progress bar.
    public var progress: Double {
        guard !Self.sections.isEmpty else { return 0 }
        return Double(completed.count) / Double(Self.sections.count)
    }

    /// The section teaching one surface, for its "learn this view" link.
    public func section(for surface: ViewSurface) -> TutorialSection? {
        Self.sections.first { $0.surface == surface }
    }

    /// Moves to the next section, marking the current one read.
    public func advance() {
        guard let selection,
            let index = Self.sections.firstIndex(where: { $0.id == selection })
        else { return }
        markComplete(selection)
        let next = Self.sections.index(after: index)
        if next < Self.sections.endIndex {
            self.selection = Self.sections[next].id
        }
    }

    private func persist() {
        defaults.set(Array(completed).sorted(), forKey: defaultsKey)
    }

    // MARK: - Content

    public static let sections: [TutorialSection] = [
        TutorialSection(
            id: "welcome",
            title: "What vbx is",
            summary: "A native front end over bv's analysis engine.",
            body: """
                vbx runs **bv's own Go engine** in-process. Every metric you see
                — PageRank, betweenness, critical path, the triage scores — is
                computed by the same code `bv` uses, so the two agree by
                construction rather than by effort.

                What vbx adds is a native surface: real tables, real charts, a
                real inspector, and macOS conveniences like Spotlight and
                Shortcuts.

                Two ideas are worth carrying into everything else:

                - **A metric that has not been computed is shown as absent**,
                  never as zero. When a cell reads `—` or `skipped`, that is
                  the truth about the metric, not a value.
                - **Readiness is a graph property.** A bead is actionable when
                  nothing unresolved blocks it — not because a field says so.
                """
        ),
        TutorialSection(
            id: "list",
            title: "The list",
            summary: "Sort, filter and search the bead set.",
            surface: .list,
            terminalKey: "l",
            body: """
                Click any column header to sort by it. The toolbar's Sort menu
                holds the same orderings, and bv's `s` cycles through them —
                all three write one value, so they can never disagree about
                what the current order is.

                The **PageRank** column stays inert until Phase 2 finishes.
                Sorting by a metric that has not been computed would order by
                nothing while looking like it worked.

                Filters (`o`, `r`, `c`, `a`) narrow by status. The search box
                composes with everything else rather than replacing it.
                """
        ),
        TutorialSection(
            id: "search",
            title: "Finding things",
            summary: "Relevance, or relevance re-ranked by the graph.",
            body: """
                Typing in the search box does a fast local match. The scope bar
                that appears offers a second mode:

                | Mode | Ranks by |
                |---|---|
                | Relevance | How well the text matches |
                | Hybrid | Text, re-scored by centrality, status, impact, priority and recency |

                Hybrid is deliberate rather than default, because it reorders
                by things other than the words you typed. Its **Weights**
                popover re-ranks live, and every result carries the breakdown
                that produced its score.
                """
        ),
        TutorialSection(
            id: "graph",
            title: "The graph",
            summary: "Dependencies as a picture.",
            surface: .graph,
            terminalKey: "g",
            body: """
                Only **blocking** dependencies shape the graph and the metrics:
                `blocks`, `conditional-blocks` and `waits-for`. An empty
                dependency type blocks too — that is bv's rule for rows written
                before the typed system — but `parent-child`, `related` and
                `discovered-from` do not.

                In a multi-repository workspace, dependencies that cross a
                repository boundary are drawn distinctly. Those are the
                coordination cost, and they are invisible from inside either
                repository.
                """
        ),
        TutorialSection(
            id: "plan",
            title: "Plan and triage",
            summary: "What to work on, and in what order.",
            surface: .plan,
            terminalKey: "p",
            body: """
                The **Plan** view groups ready work into tracks that can run in
                parallel without tripping over each other's dependencies.

                Triage scores each bead and explains itself: every
                recommendation carries the factors behind its score, so a
                ranking can be argued with rather than just accepted.

                A recommendation is not automatically claimable. A bead can be
                graph-important and still blocked — check that it is actionable
                before starting it.
                """
        ),
        TutorialSection(
            id: "sprint",
            title: "Sprints and capacity",
            summary: "Burndown against the ideal, and what more hands buy.",
            surface: .sprint,
            terminalKey: "S",
            body: """
                The burndown draws actual progress against the ideal line, and
                says in a sentence whether the sprint will land — including
                when it cannot say, because nothing has closed yet and there is
                no rate to extrapolate from.

                **Capacity** answers a different question: how long the open
                work takes with N agents. The longest dependent run is the
                floor. No number of agents beats it, which is usually the more
                useful number.
                """
        ),
        TutorialSection(
            id: "history",
            title: "History",
            summary: "Which commits actually did the work.",
            surface: .history,
            terminalKey: "t",
            body: """
                vbx reads the git object store directly rather than shelling
                out, so history works under the App Sandbox. Each link carries
                a **confidence** and the reason for it:

                | Method | Meaning |
                |---|---|
                | Named in message | The commit message references the bead |
                | Same commit | The bead's record and code changed together |

                Thumbs up raises a link to the top of its method's band; thumbs
                down removes it entirely and frees the commit to appear in the
                **Orphans** tab, which lists commits no bead accounts for.
                """
        ),
        TutorialSection(
            id: "alerts",
            title: "Alerts and drift",
            summary: "What is going wrong, and what changed.",
            surface: .alerts,
            terminalKey: "!",
            body: """
                Alerts work before you have saved anything: the checks that
                read the issue list — staleness, blocking cascades — always
                run.

                Saving a **baseline** adds the rest. Drift compares the current
                graph against that saved point, so you also see what *changed*:
                a new cycle, a density jump, actionable work drying up.
                """
        ),
        TutorialSection(
            id: "recipes",
            title: "Recipes",
            summary: "Saved views, shared with bv.",
            body: """
                A recipe sets filter, sort and view together. Applying one is a
                single click, and the built-ins — `actionable`, `high-impact`
                and the rest — are the same ones `bv --recipe` uses.

                Recipes you create are written to `.bv/recipes.yaml` in the
                project, which is bv's own location. A recipe made here works
                on the command line, and the other way round.
                """
        ),
        TutorialSection(
            id: "automation",
            title: "Automation",
            summary: "Shortcuts, URLs, Spotlight and the CLI.",
            body: """
                - **Spotlight** indexes every bead. Typing an id anywhere on the
                  system finds it and opens it here.
                - **`vbx://open?workspace=…&bead=…`** opens a workspace and
                  selects a bead — useful from a script or a note.
                - **Shortcuts** actions cover triage, the next bead, the plan,
                  alerts, a forecast and the report.
                - **Install Command Line Tool…** links `vbx-cli`, which speaks
                  the same robot protocol `bv` does.
                """
        ),
    ]
}
