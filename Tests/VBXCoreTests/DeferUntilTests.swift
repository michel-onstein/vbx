import Foundation
import Testing

@testable import VBXCore

private typealias Bead = VBXCore.Issue

// `defer_until`: decoded as a date, never a zero one, and never at the cost of
// the record. "Decoding never drops a record" — a bead lost to a malformed
// deferral would change every metric downstream.

/// The engine's decoder parses ISO 8601; `.iso8601` is the same contract
/// without reaching into VBXEngine's private one.
private func decode(_ json: String) throws -> Bead {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Bead.self, from: Data(json.utf8))
}

@Test("A present defer_until decodes to its instant")
func deferUntilPresent() throws {
    let bead = try decode(
        #"{"id":"x","title":"T","status":"open","defer_until":"2099-01-01T00:00:00Z"}"#)
    let expected = try #require(ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z"))
    #expect(bead.deferUntil == expected)
}

@Test("An absent defer_until is nil, not a zero date")
func deferUntilAbsent() throws {
    let bead = try decode(#"{"id":"x","title":"T","status":"open"}"#)
    #expect(bead.deferUntil == nil)
}

@Test(
    "A malformed defer_until is absent and the record still decodes",
    arguments: [
        #""defer_until":"next tuesday""#,
        #""defer_until":"""#,
        #""defer_until":null"#,
        #""defer_until":1234"#,
        #""defer_until":{"at":"2099"}"#,
    ])
func deferUntilMalformed(field: String) throws {
    let bead = try decode(#"{"id":"x","title":"Kept","status":"open","# + field + "}")
    #expect(bead.deferUntil == nil)
    // The record survives with everything else intact.
    #expect(bead.id == "x")
    #expect(bead.title == "Kept")
}

@Test("defer_until round-trips through encoding, and absent stays absent")
func deferUntilRoundTrip() throws {
    var bead = Bead(id: "x", title: "T")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let absent = try encoder.encode(bead)
    #expect(!String(decoding: absent, as: UTF8.self).contains("defer_until"))

    bead.deferUntil = Date(timeIntervalSince1970: 4_070_908_800)  // 2099-01-01
    let present = try decoder.decode(Bead.self, from: try encoder.encode(bead))
    #expect(present.deferUntil == bead.deferUntil)
}

@Test("Ordering by deferral puts the latest first and beads without one last")
func deferUntilOrdering() {
    var soon = Bead(id: "a", title: "soon")
    soon.deferUntil = Date(timeIntervalSince1970: 1_800_000_000)
    var later = Bead(id: "b", title: "later")
    later.deferUntil = Date(timeIntervalSince1970: 4_070_908_800)
    let none = Bead(id: "c", title: "none")

    // A first click is descending, so the deferred beads lead.
    #expect(!SortColumn.deferUntil.defaultAscending)
    let firstClick = SortMode.ordering(
        by: .deferUntil, ascending: SortColumn.deferUntil.defaultAscending)
    let descending = IssueQuery(filter: .all, sort: firstClick)
        .apply(to: [none, soon, later]).map(\.id)
    #expect(descending == ["b", "a", "c"])

    let ascending = IssueQuery(filter: .all, sort: .deferUntilAscending)
        .apply(to: [later, none, soon]).map(\.id)
    #expect(ascending == ["c", "a", "b"])

    // A date is not a metric: the ordering needs neither Phase 2 nor git.
    #expect(!SortColumn.deferUntil.requiresPhase2)
    #expect(!SortColumn.deferUntil.requiresHistory)
}
