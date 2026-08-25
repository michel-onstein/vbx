import AppKit
import VBXAppCore
import VBXCore
import Foundation
import SwiftUI
import Testing

@testable import VBXUI

/// Opening the recipe editor.
///
/// The bug this locks in: the sheet was presented by a flag beside the value it
/// edits, and `sheet(isPresented:)` builds its content from the view as it
/// stood *before* the button's write landed — so `editing` still read nil, the
/// window opened with an empty body, and it stayed empty until some unrelated
/// change re-ran the sidebar's body. In a live app that was around twenty
/// seconds; against a workspace nothing else is touching it never filled in.
///
/// The assertion is the sheet's *size*: the editor asks for 520×620, and an
/// empty body asks for nothing. See BUGS.md, 2026-08-24.
@MainActor
@Suite("Recipe editor presentation")
struct RecipeEditorPresentationTests {

    @Test("Clicking New recipe opens an editor that already has its content")
    func editorOpensWithContent() async throws {
        let store = await Fixture.loadedStore()
        await store.loadRecipes()

        let size = CGSize(width: 280, height: 460)
        let host = NSHostingView(
            rootView: AnyView(
                List { SidebarRecipesSection() }
                    .environmentObject(store)
                    .frame(width: size.width, height: size.height)
            ))
        host.frame = CGRect(origin: .zero, size: size)

        // A titled window that is on screen: a sheet attaches to its parent,
        // and AppKit will not run one on a window it is not showing.
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)

        host.layoutSubtreeIfNeeded()
        settle(0.5)

        // "New recipe…" is the section's last row. Clicked through the list's
        // own row views rather than at a fixed coordinate, so the number of
        // recipes the workspace carries cannot move the target.
        let rows = listRows(in: host)
        #expect(rows.count > 1, "the recipes section rendered \(rows.count) rows")
        let newRecipeRow = try #require(rows.last, "no rows in the recipes section")
        click(newRecipeRow, in: window)

        settle(1.0)

        let sheet = try #require(window.attachedSheet, "no editor sheet was presented")
        // 520×620 is what RecipeEditor asks for. An empty body asks for
        // nothing, which is what the flag-driven sheet opened as.
        #expect(
            sheet.frame.width >= 500 && sheet.frame.height >= 500,
            "the editor opened at \(sheet.frame.size) — an empty sheet, not the form")

        window.attachedSheet.map { window.endSheet($0) }
        window.orderOut(nil)
        await store.close()
    }

    /// Runs the main run loop so SwiftUI can resolve lazy content and AppKit
    /// can run the sheet presentation — neither happens inside layout.
    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The row views SwiftUI's `List` builds, top to bottom.
    ///
    /// A `List` on macOS is an `NSTableView`, so its rows are real views and a
    /// click can be aimed at one by position in the list rather than by a
    /// coordinate a differently-sized workspace would invalidate.
    private func listRows(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if view is NSTableRowView { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.sorted {
            $0.convert($0.bounds.origin, to: root).y < $1.convert($1.bounds.origin, to: root).y
        }
    }

    private func click(_ view: NSView, in window: NSWindow) {
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = view.convert(centre, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            window.sendEvent(event)
        }
    }
}
