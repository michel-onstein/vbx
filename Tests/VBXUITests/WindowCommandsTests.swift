import Foundation
import Testing

/// How windows are opened.
///
/// ## Why this reads source
///
/// SwiftUI's scene graph cannot be inspected: there is no value to assert
/// against, the way `IssueListView.specs` replaced the column tests that used
/// to parse source. And the bug this guards is invisible to the compiler —
/// `openWindow(value:)` is generic over `Codable & Hashable`, so passing an
/// `Optional` type-checks perfectly and then matches no scene at runtime.
/// Nothing fails; the menu item simply does nothing.
///
/// So this asserts the *absence of a known-bad call shape*, which is a stable
/// thing to assert. That is the difference from the column tests: those parsed
/// structure that legitimately changes shape, and silently matched nothing the
/// moment it did.
@Suite("Window commands")
struct WindowCommandsTests {

    private static func appSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/vbx/VBXApp.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Source with comments removed — the explanation of a bug names the bug.
    private static func code() throws -> String {
        try appSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("No window is opened with an optional value")
    func noOptionalWindowValues() throws {
        // `openWindow(value: String?.none)` compiled, matched no scene, and
        // opened nothing — File ▸ New Window was inert. The scene is declared
        // `for: String.self`; nothing declares `String?`.
        let code = try Self.code()
        #expect(!code.contains("openWindow(value: String?.none)"))
        #expect(
            !code.contains("?.none"),
            "an optional is being passed where SwiftUI resolves a scene by type")
    }

    @Test("A window with no workspace is opened by id")
    func newWindowOpensByID() throws {
        let code = try Self.code()
        // The only way to present a value-based group with no value.
        #expect(code.contains("openWindow(id: VBXApp.workspaceWindowID)"))
        #expect(code.contains("static let workspaceWindowID"))
    }

    @Test("The group carries the identifier the command opens")
    func groupAndCommandAgree() throws {
        // Two halves of one contract, and a literal in either would let them
        // drift silently — the same failure mode as a column's identifier not
        // matching its SortColumn.
        let code = try Self.code()
        #expect(code.contains("WindowGroup(id: Self.workspaceWindowID, for: String.self)"))
    }

    @Test("Opening a recent workspace still passes a plain String")
    func recentsPassAValue() throws {
        // This route always worked, and is why one menu item opened windows
        // while the other did not. It must keep passing a non-optional.
        let code = try Self.code()
        #expect(code.contains("openWindow(value: entry.path)"))
    }
}
