import Foundation
import Testing

@testable import VBXCore

/// Swift Testing exports its own `Issue` type, so the model type is aliased
/// here to keep every reference unambiguous.
private typealias Bead = VBXCore.Issue

// MARK: - Decoding tolerance
//
// These tests pin the behaviours where a strict decoder would silently drop
// data. Dropping an issue changes every graph metric downstream, so each of
// these is a correctness guard, not a nicety.

@Test("An unrecognised status decodes rather than throwing")
func unknownStatusSurvives() throws {
    let json = #"{"id":"x","title":"T","status":"molecule","issue_type":"task"}"#
    let issue = try JSONDecoder().decode(Bead.self, from: Data(json.utf8))

    #expect(issue.status == .unknown("molecule"))
    #expect(issue.status.rawValue == "molecule")
    #expect(issue.status.displayName == "Molecule")
    // An unknown status is neither open nor closed.
    #expect(!issue.status.isOpen)
    #expect(!issue.status.isClosed)
}

@Test(
    "All of bv's statuses round-trip",
    arguments: [
        "open", "in_progress", "blocked", "deferred", "draft",
        "pinned", "hooked", "review", "closed", "tombstone",
    ])
func allStatusesRoundTrip(raw: String) {
    let status = IssueStatus(rawValue: raw)
    #expect(status.rawValue == raw)
    // None of bv's own statuses may fall through to the catch-all case.
    var recognised = true
    if case .unknown = status { recognised = false }
    #expect(recognised)
}

@Test("An unrecognised issue type is valid, not an error")
func unknownIssueTypeIsValid() throws {
    let json = #"{"id":"x","title":"T","status":"open","issue_type":"role"}"#
    let issue = try JSONDecoder().decode(Bead.self, from: Data(json.utf8))

    #expect(issue.type == .other("role"))
    #expect(!issue.type.isKnown)
    #expect(issue.type.rawValue == "role")
}

@Test(
    "Dependency accepts all three target field spellings",
    arguments: [
        (#"{"issue_id":"a","depends_on_id":"b"}"#, "b"),
        (#"{"issue_id":"a","depends_on":"c"}"#, "c"),
        (#"{"issue_id":"a","target_id":"d"}"#, "d"),
        // Canonical wins when several are present.
        (#"{"issue_id":"a","depends_on_id":"b","depends_on":"c","target_id":"d"}"#, "b"),
    ])
func dependencyTargetAliases(json: String, expected: String) throws {
    let dep = try JSONDecoder().decode(Dependency.self, from: Data(json.utf8))
    #expect(dep.dependsOnID == expected)
}

@Test("Comment ids decode from both UUID strings and legacy integers")
func commentIDShapes() throws {
    let uuid = #"{"id":"019d9b8d-e35f-7ce4-9714-d304b1eb90b0","issue_id":"x","author":"a","text":"t"}"#
    let legacy = #"{"id":42,"issue_id":"x","author":"a","text":"t"}"#
    let missing = #"{"issue_id":"x","author":"a","text":"t"}"#

    #expect(try JSONDecoder().decode(Comment.self, from: Data(uuid.utf8)).id
        == "019d9b8d-e35f-7ce4-9714-d304b1eb90b0")
    #expect(try JSONDecoder().decode(Comment.self, from: Data(legacy.utf8)).id == "42")
    #expect(try JSONDecoder().decode(Comment.self, from: Data(missing.utf8)).id == "")
}

// MARK: - Blocking semantics

@Test("blocks, conditional-blocks, waits-for and the empty type block")
func blockingSemantics() {
    #expect(DependencyType.blocks.isBlocking)
    // Legacy rows written before the typed system have no type and must
    // still block; bv's IsBlocking returns true for "".
    #expect(DependencyType(rawValue: "").isBlocking)

    #expect(!DependencyType.related.isBlocking)
    #expect(!DependencyType.parentChild.isBlocking)
    #expect(!DependencyType.discoveredFrom.isBlocking)
    #expect(!DependencyType(rawValue: "custom-link").isBlocking)
}

// Regression (vbx-850): bv v0.25.0 made waits-for and conditional-blocks
// blocking, and the engine follows it; Swift still said they did not, so the
// graph and inspector disagreed with the engine's actionable set and metrics.
@Test("waits-for and conditional-blocks block, as in bv v0.25")
func waitsForAndConditionalBlocksBlock() {
    #expect(DependencyType(rawValue: "waits-for") == .waitsFor)
    #expect(DependencyType(rawValue: "conditional-blocks") == .conditionalBlocks)
    #expect(DependencyType.waitsFor.isBlocking)
    #expect(DependencyType.conditionalBlocks.isBlocking)

    let issue = Bead(
        id: "a", title: "A",
        dependencies: [
            Dependency(issueID: "a", dependsOnID: "w", type: DependencyType(rawValue: "waits-for")),
            Dependency(issueID: "a", dependsOnID: "c", type: DependencyType(rawValue: "conditional-blocks")),
            Dependency(issueID: "a", dependsOnID: "p", type: .parentChild),
        ])
    #expect(issue.blockingDependencies.map(\.dependsOnID).sorted() == ["c", "w"])
}

@Test("Named dependency types keep their raw value, and unknown ones stay open")
func dependencyTypeRoundTrip() throws {
    let raws = [
        "blocks", "conditional-blocks", "waits-for", "related", "parent-child",
        "discovered-from", "", "custom-link",
    ]
    for raw in raws {
        #expect(DependencyType(rawValue: raw).rawValue == raw)
        let json = "{\"issue_id\":\"a\",\"depends_on_id\":\"b\",\"type\":\"\(raw)\"}"
        let decoded = try JSONDecoder().decode(Dependency.self, from: Data(json.utf8))
        #expect(decoded.type.rawValue == raw)
    }
    #expect(DependencyType(rawValue: "custom-link") == .other("custom-link"))
}

// vbx-j7r: SourceKind had no workspace case, and its decoder read anything it
// did not know as JSONL — so a multi-repository session reported "JSONL".
@Test(
    "Every source kind the engine reports decodes as itself, and an unknown one stays open",
    arguments: [
        ("jsonl", SourceKind.jsonl),
        ("jsonl_local", SourceKind.jsonl),
        ("sqlite", SourceKind.sqlite),
        ("workspace", SourceKind.workspace),
        ("jsonl_worktree", SourceKind.unknown("jsonl_worktree")),
    ])
func sourceKindDecodes(raw: String, expected: SourceKind) throws {
    let json = #"{"source":"/x/.beads/issues.jsonl","kind":"\#(raw)","issue_count":1}"#
    let info = try JSONDecoder().decode(WorkspaceInfo.self, from: Data(json.utf8))
    #expect(info.kind == expected)
    // The kind round-trips through the engine's spelling.
    let encoded = try JSONEncoder().encode(info.kind)
    #expect(try JSONDecoder().decode(SourceKind.self, from: encoded) == expected)
}

@Test("A workspace session is named for its root, not its .bv folder")
func workspaceDisplayName() {
    let workspace = WorkspaceInfo(
        source: "/src/platform/.bv/workspace.yaml", kind: .workspace, issueCount: 4, dataHash: "h")
    #expect(workspace.displayName == "platform")
    #expect(workspace.kind.displayName == "Workspace")
    let single = WorkspaceInfo(
        source: "/src/platform/.beads/issues.jsonl", kind: .jsonl, issueCount: 4, dataHash: "h")
    #expect(single.displayName == "platform")
}

@Test("blockingDependencies filters out non-blocking edges")
func blockingDependenciesFilter() {
    let issue = Issue(
        id: "a", title: "A",
        dependencies: [
            Dependency(issueID: "a", dependsOnID: "b", type: .blocks),
            Dependency(issueID: "a", dependsOnID: "c", type: .related),
            Dependency(issueID: "a", dependsOnID: "d", type: .parentChild),
            Dependency(issueID: "a", dependsOnID: "e", type: DependencyType(rawValue: "")),
        ])

    #expect(issue.blockingDependencies.map(\.dependsOnID).sorted() == ["b", "e"])
}
