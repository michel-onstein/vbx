import Foundation

/// A flag that means something only beside certain others — bv's
/// `modifierFlagRule`, from `cmd/bv/main.go` at the engine's beads_viewer
/// version.
///
/// vbx-cli refuses a modifier given without any flag it requires, as bv does:
/// bv's message word for word, and bv's exit status 1. The rule is the one
/// description of where a modifier applies, so vbx-cli's `--help` is printed
/// from it too and cannot claim a combination the parser refuses.
public struct ModifierRule: Sendable, Equatable {
    /// The modifier, without the leading `--`.
    public let flag: String
    /// The flags any one of which makes the modifier valid, under bv's names
    /// and in bv's order — the order its error lists them in. Some are bv
    /// spellings vbx-cli writes differently (`bead-history` is
    /// `--robot-history --id`) or does not have (`robot-triage-by-track`);
    /// the caller decides which are active.
    public let requires: [String]
    /// The help section the modifier is listed under, or nil for a rule over
    /// a command flag (`--robot-search`, `--robot-diff`), which the command
    /// list already names.
    public let section: ModifierSection?
    /// The flag as written in `--help`, with its value placeholder.
    public let usage: String
    /// What it does, for `--help`.
    public let help: String

    init(
        _ flag: String, requires: [String], section: ModifierSection?, usage: String? = nil,
        help: String = ""
    ) {
        self.flag = flag
        self.requires = requires
        self.section = section
        self.usage = usage ?? "--\(flag)"
        self.help = help
    }

    /// bv's error, `formatRequiredFlags` included: one flag is named bare,
    /// several as "one of --a, --b or --c". bv follows it with a `Try:` line
    /// naming a bv invocation, which vbx-cli replaces with its own pointer to
    /// `--help`.
    public var message: String {
        let names = requires.map { "--\($0)" }
        let required: String
        switch names.count {
        case 0: required = "another flag"
        case 1: required = names[0]
        default:
            required = "one of " + names.dropLast().joined(separator: ", ") + " or " + names.last!
        }
        return "--\(flag) requires \(required)"
    }
}

/// Where `--help` lists a modifier.
public enum ModifierSection: String, Sendable, CaseIterable {
    case export, search, suggest, graph, alerts, history, triage, forecast, capacity, priority
}

public enum ModifierRules {
    /// bv's modifier rules for every modifier vbx-cli accepts, in bv's order:
    /// bv reports the first rule that fails, so two misused modifiers are
    /// refused with the same message by both. Rules for flags vbx-cli does
    /// not have (`--search-weights`, `--graph-preset`, the pages and debug
    /// flags) are left out, since a flag it does not parse is refused before
    /// any rule is consulted.
    public static let all: [ModifierRule] = [
        ModifierRule(
            "export-format", requires: ["export", "export-md"], section: .export,
            usage: "--export-format markdown|json|csv|mermaid", help: "The report's format"),
        ModifierRule(
            "export-include-graph", requires: ["export", "export-md"], section: .export,
            usage: "--export-include-graph[=false]",
            help: "Include the dependency context (default: all but csv)"),
        ModifierRule(
            "export-template", requires: ["export", "export-md"], section: .export,
            usage: "--export-template FILE",
            help: "A Go text/template for the Markdown report; --export-template= disables a recipe's"),
        ModifierRule("robot-diff", requires: ["diff-since"], section: nil),
        ModifierRule("robot-search", requires: ["search"], section: nil),
        ModifierRule(
            "search-limit", requires: ["search"], section: .search,
            usage: "--search-limit N", help: "Results returned (default 10)"),
        ModifierRule(
            "search-min-score", requires: ["search"], section: .search,
            usage: "--search-min-score S",
            help: "Minimum text similarity before hybrid ranking (-1..1); exact ids also obey it"),
        ModifierRule(
            "search-mode", requires: ["search"], section: .search,
            usage: "--search-mode text|hybrid", help: "How results are ranked"),
        ModifierRule(
            "search-preset", requires: ["search"], section: .search,
            usage: "--search-preset NAME", help: "The hybrid ranking's weight preset"),
        ModifierRule(
            "suggest-type", requires: ["robot-suggest"], section: .suggest,
            usage: "--suggest-type T", help: "Only duplicate, dependency, label or cycle"),
        ModifierRule(
            "suggest-confidence", requires: ["robot-suggest"], section: .suggest,
            usage: "--suggest-confidence C", help: "Suggestions at or above C (0.0-1.0)"),
        ModifierRule(
            "suggest-bead", requires: ["robot-suggest"], section: .suggest,
            usage: "--suggest-bead ID", help: "Only suggestions involving the bead"),
        ModifierRule(
            "graph-format", requires: ["robot-graph"], section: .graph,
            usage: "--graph-format json|dot|mermaid", help: "The export's format"),
        ModifierRule(
            "graph-root",
            requires: ["robot-graph", "robot-triage", "robot-triage-by-track", "robot-triage-by-label",
                       "robot-next"],
            section: .graph, usage: "--graph-root ID",
            help: "The subgraph below a bead: what the graph exports, and what triage and next rank"),
        ModifierRule(
            "graph-depth", requires: ["robot-graph"], section: .graph,
            usage: "--graph-depth N", help: "How deep below --graph-root (default 0, unlimited)"),
        ModifierRule(
            "severity", requires: ["robot-alerts"], section: .alerts,
            usage: "--severity S", help: "Only info, warning or critical alerts"),
        ModifierRule(
            "alert-type", requires: ["robot-alerts"], section: .alerts,
            usage: "--alert-type T", help: "Only alerts of the type, e.g. stale_issue"),
        ModifierRule(
            "alert-label", requires: ["robot-alerts"], section: .alerts,
            usage: "--alert-label L", help: "Only alerts matching the label (not the --label scope)"),
        ModifierRule(
            "history-since", requires: ["robot-history", "bead-history", "robot-causality"],
            section: .history, usage: "--history-since S", help: "Commits after S"),
        ModifierRule(
            "history-limit", requires: ["robot-history", "bead-history", "robot-causality"],
            section: .history, usage: "--history-limit N",
            help: "Commits walked (default 500, 0 for all)"),
        ModifierRule(
            "robot-not-ready-labels",
            requires: ["robot-triage", "robot-triage-by-track", "robot-triage-by-label", "robot-next"],
            section: .triage, usage: "--robot-not-ready-labels A,B",
            help: "Labels whose beads are never a claimable top pick (env: BV_ROBOT_NOT_READY_LABELS)"),
        ModifierRule(
            "min-confidence", requires: ["robot-history", "bead-history"], section: .history,
            usage: "--min-confidence C", help: "Links at or above C (0.0-1.0)"),
        ModifierRule(
            "orphans-min-score", requires: ["robot-orphans"], section: .history,
            usage: "--orphans-min-score N", help: "Minimum suspicion score (0-100, default 30)"),
        ModifierRule(
            "file-beads-limit", requires: ["robot-file-beads"], section: .history,
            usage: "--file-beads-limit N", help: "Closed beads shown (default 20)"),
        ModifierRule(
            "hotspots-limit", requires: ["robot-file-hotspots"], section: .history,
            usage: "--hotspots-limit N", help: "Hotspots shown (default 10)"),
        ModifierRule(
            "relations-threshold", requires: ["robot-file-relations"], section: .history,
            usage: "--relations-threshold T", help: "Minimum co-change correlation (0.0-1.0)"),
        ModifierRule(
            "relations-limit", requires: ["robot-file-relations"], section: .history,
            usage: "--relations-limit N", help: "Related files shown (default 10)"),
        ModifierRule(
            "related-min-relevance", requires: ["robot-related"], section: .history,
            usage: "--related-min-relevance P", help: "Percent 0-100, or a fraction 0.0-1.0"),
        ModifierRule(
            "related-max-results", requires: ["robot-related"], section: .history,
            usage: "--related-max-results N", help: "Results per category (default 10)"),
        ModifierRule(
            "related-include-closed", requires: ["robot-related"], section: .history,
            help: "Include closed beads"),
        ModifierRule(
            "network-depth", requires: ["robot-impact-network"], section: .history,
            usage: "--network-depth N", help: "The subnetwork's depth around a bead (1-3)"),
        ModifierRule(
            "forecast-label", requires: ["robot-forecast"], section: .forecast,
            usage: "--forecast-label L", help: "Only beads carrying the label (not the --label scope)"),
        ModifierRule(
            "forecast-sprint", requires: ["robot-forecast"], section: .forecast,
            usage: "--forecast-sprint S", help: "Only the sprint's beads"),
        ModifierRule(
            "forecast-agents", requires: ["robot-forecast"], section: .forecast,
            usage: "--forecast-agents N", help: "Agents working in parallel (default 1)"),
        ModifierRule(
            "agents", requires: ["robot-capacity"], section: .capacity,
            usage: "--agents N", help: "Agents working in parallel (default 1)"),
        ModifierRule(
            "capacity-label", requires: ["robot-capacity"], section: .capacity,
            usage: "--capacity-label L", help: "Only beads carrying the label (not the --label scope)"),
        ModifierRule(
            "robot-by-label", requires: ["robot-priority"], section: .priority,
            usage: "--robot-by-label L", help: "Only recommendations for beads carrying the label"),
        ModifierRule(
            "robot-by-assignee", requires: ["robot-priority"], section: .priority,
            usage: "--robot-by-assignee A", help: "Only recommendations for the assignee's beads"),
    ]

    /// The rule for a modifier, by name without `--`.
    public static func rule(_ flag: String) -> ModifierRule? {
        all.first { $0.flag == flag }
    }

    /// Every flag a modifier is given beside: bv's `validateModifierFlags`.
    /// `given` holds each flag on the command line, set or not — bv's
    /// `Changed` — and `isActive` says whether a required flag, under bv's
    /// name, is in effect: a command selected, a value that is not blank.
    /// Returns the first broken rule's message, nil when none is broken.
    public static func violation(
        given: Set<String>, isActive: (String) -> Bool
    ) -> String? {
        for rule in all where given.contains(rule.flag) {
            if !rule.requires.contains(where: isActive) { return rule.message }
        }
        return nil
    }

    /// The help lines for a section: each modifier with what it needs beside
    /// it, named as vbx-cli spells it. `spelling` maps a required bv flag to
    /// vbx-cli's, or to nil for one vbx-cli has no flag for.
    public static func helpLines(
        _ section: ModifierSection, spelling: (String) -> String?, width: Int = 79
    ) -> [String] {
        let indent = String(repeating: " ", count: 23)
        var lines: [String] = []
        for rule in all where rule.section == section {
            var names: [String] = []
            for required in rule.requires {
                if let name = spelling(required), !names.contains(name) { names.append(name) }
            }
            let text = rule.help + (names.isEmpty ? "" : "; with " + names.joined(separator: ", "))
            let head = "  " + rule.usage
            if head.count <= indent.count - 1 {
                let padded = head.padding(toLength: indent.count, withPad: " ", startingAt: 0)
                lines.append(contentsOf: wrap(text, first: padded, indent: indent, width: width))
            } else {
                lines.append(head)
                lines.append(contentsOf: wrap(text, first: indent, indent: indent, width: width))
            }
        }
        return lines
    }

    /// Wraps text at word boundaries, the first line after `first`.
    static func wrap(_ text: String, first: String, indent: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = first
        var empty = true
        for word in text.split(separator: " ") {
            if !empty, line.count + 1 + word.count > width {
                lines.append(line)
                line = indent
                empty = true
            }
            line += (empty ? "" : " ") + word
            empty = false
        }
        if !empty { lines.append(line) }
        return lines
    }
}

/// A flag whose value must be one of a fixed set — bv's `enumFlagRule`, from
/// `cmd/bv/main.go` at the engine's beads_viewer version. bv checks these
/// right after its modifier rules, with the same exit status 1.
public struct EnumRule: Sendable, Equatable {
    /// The flag, without the leading `--`.
    public let flag: String
    /// The values it accepts, in bv's order — the order its error lists them.
    public let allowed: [String]

    /// bv's `validateEnumFlags` for one given value: nil when the value,
    /// trimmed and lowercased, is allowed, else bv's message word for word,
    /// with its "did you mean" when a value is close enough.
    public func violation(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expected = "invalid --\(flag) \(goQuoted(value)) (expected one of "
            + allowed.joined(separator: ", ") + ")"
        if normalized.isEmpty { return expected }
        if allowed.contains(normalized) { return nil }
        guard let suggestion = closest(to: normalized) else { return expected }
        return expected + "; did you mean \(goQuoted(suggestion))?"
    }

    /// bv's `suggestClosest`: the nearest allowed value by byte edit distance,
    /// within a bound that grows with the value's length; a tie goes to the
    /// candidate that sorts first, by bv's own comparison.
    func closest(to value: String) -> String? {
        var best: String?
        var bestDistance: Int
        switch value.utf8.count {
        case ...4: bestDistance = 2
        case ...10: bestDistance = 3
        default: bestDistance = 4
        }
        for candidate in allowed {
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty { continue }
            let distance = EnumRule.editDistance(value, normalized)
            if distance <= bestDistance,
                best == nil || distance < bestDistance || normalized < best!.lowercased()
            {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    /// bv's `levenshteinDistance`, over bytes as Go indexes a string.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8)
        let b = Array(b.utf8)
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Go's `%q` for the values a flag is given: quoted, with the quote, the
/// backslash and the common control characters escaped.
func goQuoted(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7f {
                out += String(format: "\\x%02x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

public enum EnumRules {
    /// bv's enum rules for every enum flag vbx-cli accepts, in bv's order.
    /// bv's `--script-format` is left out: vbx-cli has no `--emit-script`.
    public static let all: [EnumRule] = [
        EnumRule(flag: "graph-format", allowed: ["json", "dot", "mermaid"])
    ]

    /// The first given flag whose value is not allowed: bv's
    /// `validateEnumFlags`. `value` returns a flag's value as given, or nil
    /// when the flag was not on the command line — bv's `Changed`.
    public static func violation(value: (String) -> String?) -> String? {
        for rule in all {
            if let given = value(rule.flag), let message = rule.violation(given) {
                return message
            }
        }
        return nil
    }
}
