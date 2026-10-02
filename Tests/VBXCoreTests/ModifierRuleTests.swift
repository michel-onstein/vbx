import Foundation
import Testing

@testable import VBXCore

/// vbx-cli's spelling of bv's active flags, for a command and the flags given
/// beside it — the shape of the CLI's `isActive`, small enough to state here.
private func active(command: String?, id: String? = nil, also: Set<String> = []) -> (String) -> Bool {
    { flag in
        if also.contains(flag) { return true }
        if flag == "bead-history" { return command == "robot-history" && id != nil }
        return flag == command
    }
}

@Test("bv's message names one required flag bare, and several as one of a, b or c")
func modifierMessages() {
    #expect(ModifierRules.rule("orphans-min-score")?.message
        == "--orphans-min-score requires --robot-orphans")
    #expect(ModifierRules.rule("min-confidence")?.message
        == "--min-confidence requires one of --robot-history or --bead-history")
    #expect(ModifierRules.rule("history-limit")?.message
        == "--history-limit requires one of --robot-history, --bead-history or --robot-causality")
}

// Regression (vbx-uao): vbx-cli answered --robot-orphans --history-limit 3
// where bv refuses it.
@Test(
    "Every history modifier is refused beside a command that does not take it",
    arguments: [
        ("history-limit", "robot-orphans"), ("history-since", "robot-file-hotspots"),
        ("min-confidence", "robot-priority"), ("orphans-min-score", "robot-file-hotspots"),
        ("file-beads-limit", "robot-file-relations"), ("hotspots-limit", "robot-orphans"),
        ("relations-threshold", "robot-file-beads"), ("relations-limit", "robot-impact"),
        ("related-min-relevance", "robot-causality"), ("related-max-results", "robot-history"),
        ("related-include-closed", "robot-impact-network"), ("network-depth", "robot-related"),
    ])
func historyModifierRefused(modifier: String, command: String) {
    let message = ModifierRules.violation(given: [modifier, command], isActive: active(command: command))
    #expect(message == ModifierRules.rule(modifier)?.message)
    #expect(message?.hasPrefix("--\(modifier) requires ") == true)
}

@Test(
    "A modifier beside a command it modifies is accepted",
    arguments: [
        ("history-limit", "robot-history"), ("history-limit", "robot-causality"),
        ("history-since", "robot-causality"), ("min-confidence", "robot-history"),
        ("orphans-min-score", "robot-orphans"), ("file-beads-limit", "robot-file-beads"),
        ("hotspots-limit", "robot-file-hotspots"), ("relations-limit", "robot-file-relations"),
        ("related-include-closed", "robot-related"), ("network-depth", "robot-impact-network"),
        ("forecast-agents", "robot-forecast"), ("agents", "robot-capacity"),
        ("severity", "robot-alerts"), ("robot-not-ready-labels", "robot-next"),
        ("robot-by-label", "robot-priority"), ("suggest-confidence", "robot-suggest"),
    ])
func modifierAccepted(modifier: String, command: String) {
    #expect(ModifierRules.violation(given: [modifier], isActive: active(command: command)) == nil)
}

@Test("bv's --bead-history is active as --robot-history with an id")
func beadHistoryCounts() {
    #expect(ModifierRules.violation(
        given: ["history-limit"], isActive: active(command: "robot-history", id: "x")) == nil)
}

@Test("A flag that is not a command — --export, --search — satisfies its modifiers")
func flagRequirements() {
    #expect(ModifierRules.violation(
        given: ["export-format"], isActive: active(command: nil, also: ["export-md"])) == nil)
    #expect(ModifierRules.violation(
        given: ["search-mode"], isActive: active(command: "robot-triage")) != nil)
    #expect(ModifierRules.violation(
        given: ["robot-search", "search-mode"],
        isActive: active(command: "robot-search", also: ["search"])) == nil)
}

@Test("Two misused modifiers are refused for the first in bv's order")
func firstRuleWins() {
    // bv lists history-since before history-limit, whatever the command line's order.
    let message = ModifierRules.violation(
        given: ["history-limit", "history-since", "robot-orphans"],
        isActive: active(command: "robot-orphans"))
    #expect(message?.hasPrefix("--history-since ") == true)
}

@Test("Each modifier has one rule, and each rule requires something")
func rulesAreWellFormed() {
    let flags = ModifierRules.all.map(\.flag)
    #expect(Set(flags).count == flags.count)
    #expect(ModifierRules.all.allSatisfy { !$0.requires.isEmpty })
    // Every listed modifier says what it does.
    #expect(ModifierRules.all.filter { $0.section != nil }.allSatisfy { !$0.help.isEmpty })
}

// vbx-pfy: vbx-cli spelled four of bv's modifiers its own way, so bv's rules
// for them could not apply. They take bv's names and bv's rules now.
@Test("bv's search, suggest and graph modifiers have bv's rules")
func renamedModifierRules() {
    #expect(ModifierRules.rule("search-limit")?.message == "--search-limit requires --search")
    #expect(ModifierRules.rule("suggest-bead")?.message
        == "--suggest-bead requires --robot-suggest")
    #expect(ModifierRules.rule("graph-depth")?.message == "--graph-depth requires --robot-graph")
    #expect(ModifierRules.rule("graph-root")?.message
        == "--graph-root requires one of --robot-graph, --robot-triage, --robot-triage-by-track,"
        + " --robot-triage-by-label or --robot-next")
    // vbx-cli's own spellings are gone, with no rule left behind for them.
    for old in ["limit", "depth", "root", "threshold"] {
        #expect(ModifierRules.rule(old) == nil)
    }
}

@Test(
    "--graph-root modifies the graph, triage and next, and nothing else",
    arguments: [
        ("robot-graph", true), ("robot-triage", true), ("robot-next", true),
        ("robot-plan", false), ("robot-insights", false), ("robot-suggest", false),
    ])
func graphRootCommands(command: String, accepted: Bool) {
    let message = ModifierRules.violation(
        given: ["graph-root", command], isActive: active(command: command))
    #expect((message == nil) == accepted)
}

@Test("--search-limit needs a query, not just --robot-search")
func searchLimitNeedsQuery() {
    #expect(ModifierRules.violation(
        given: ["search-limit", "robot-search"], isActive: active(command: "robot-search"))
        == "--robot-search requires --search")
    #expect(ModifierRules.violation(
        given: ["search-limit"], isActive: active(command: "robot-triage"))
        == "--search-limit requires --search")
    #expect(ModifierRules.violation(
        given: ["search-limit", "robot-search", "search"],
        isActive: active(command: "robot-search", also: ["search"])) == nil)
}

@Test(
    "--graph-format is refused outside bv's values, with bv's message",
    arguments: [
        ("svg", #"invalid --graph-format "svg" (expected one of json, dot, mermaid)"#),
        ("dott",
         #"invalid --graph-format "dott" (expected one of json, dot, mermaid); did you mean "dot"?"#),
        ("", #"invalid --graph-format "" (expected one of json, dot, mermaid)"#),
        ("mermiad",
         #"invalid --graph-format "mermiad" (expected one of json, dot, mermaid); did you mean "mermaid"?"#),
        ("js",
         #"invalid --graph-format "js" (expected one of json, dot, mermaid); did you mean "json"?"#),
        ("graphviz", #"invalid --graph-format "graphviz" (expected one of json, dot, mermaid)"#),
        (#"a"b"#, #"invalid --graph-format "a\"b" (expected one of json, dot, mermaid)"#),
    ])
func graphFormatRefused(value: String, message: String) {
    #expect(EnumRules.violation { $0 == "graph-format" ? value : nil } == message)
}

@Test("--graph-format accepts bv's values whatever their case and padding")
func graphFormatAccepted() {
    for value in ["json", "dot", "mermaid", "DOT", " json ", "Mermaid"] {
        #expect(EnumRules.violation { $0 == "graph-format" ? value : nil } == nil, "\(value)")
    }
    // A flag that was not given is never checked.
    #expect(EnumRules.violation { _ in nil } == nil)
}

@Test("--help lists a modifier with what it needs, in vbx-cli's spelling")
func helpLinesFollowTheRule() {
    let lines = ModifierRules.helpLines(.history) { flag in
        flag == "bead-history" ? nil : "--" + flag
    }
    let text = lines.joined(separator: "\n")
    #expect(text.contains("--history-limit N"))
    #expect(text.contains("--robot-history,"))
    #expect(!text.contains("bead-history"))
    #expect(lines.allSatisfy { $0.count <= 79 })
    // A modifier that is not listed in its section's help is in another.
    let listed = ModifierSection.allCases.flatMap {
        ModifierRules.helpLines($0) { "--" + $0 }
    }.joined(separator: "\n")
    for rule in ModifierRules.all where rule.section != nil {
        #expect(listed.contains(rule.usage), "\(rule.flag) is missing from --help")
    }
}
