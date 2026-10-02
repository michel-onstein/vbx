import Foundation

/// A report the store reads from the engine and something on screen shows.
///
/// **An unavailable report is shown as unavailable, never as an empty one.**
/// An empty report is a claim — "no alerts", "no labels", "every commit belongs
/// to a bead", "unblocks 0" — and a failed call never made it. Every panel used
/// to make it anyway, because each call site read `(try? …) ?? .empty`
/// (vbx-lh0 for the orphans, vbx-twy for the rest). Now each read goes through
/// ``ProjectStore/fetch(_:_:)``, which publishes the failure under its report
/// in ``ProjectStore/unavailable``, and the views ask for it there.
public enum EngineReport: String, CaseIterable, Sendable {
    // History, read alongside the correlation walk.
    case orphans
    case hotspots
    case correlationFeedback
    // Workspace analysis, read on every load.
    case labelHealth
    case labelFlow
    case labelAttention
    case repos
    case triage
    case triageFeedback
    case alerts
    case baseline
    // Read when a surface asks.
    case searchPresets
    case search
    case sprints
    case capacity
    case recipes
    case revisions
    // Read for one bead, path or commit.
    case causality
    case fileLookup
    case patch
    case unblocks
    case cloudflareInstructions

    /// The report's name in "<name> unavailable".
    public var displayName: String {
        switch self {
        case .orphans: "Orphans"
        case .hotspots: "Hotspots"
        case .correlationFeedback: "Correlation feedback"
        case .labelHealth: "Label health"
        case .labelFlow: "Label flow"
        case .labelAttention: "Attention scores"
        case .repos: "Repositories"
        case .triage: "Triage"
        case .triageFeedback: "Triage feedback"
        case .alerts: "Alerts"
        case .baseline: "Baseline"
        case .searchPresets: "Search presets"
        case .search: "Hybrid ranking"
        case .sprints: "Sprints"
        case .capacity: "Capacity"
        case .recipes: "Recipes"
        case .revisions: "Revisions"
        case .causality: "Causal chain"
        case .fileLookup: "File history"
        case .patch: "Diff"
        case .unblocks: "Unblocks"
        case .cloudflareInstructions: "Cloudflare instructions"
        }
    }

    /// Read alongside the correlation walk, and forgotten with it.
    public var isHistory: Bool {
        switch self {
        case .orphans, .hotspots, .correlationFeedback, .causality, .fileLookup, .patch: true
        default: false
        }
    }
}
