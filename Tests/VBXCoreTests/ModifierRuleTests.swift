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
