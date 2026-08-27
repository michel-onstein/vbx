import AppKit
import VBXAppCore
import VBXUI
import VBXCore
import CoreSpotlight
import SwiftUI

@main
struct VBXApp: App {
    /// The workspace window group's identifier.
    ///
    /// Needed to open a window with *no* workspace. `openWindow(value:)`
    /// resolves a scene by the type of the value it is given, and there is no
    /// scene for "absence" — see ``VBXCommands`` for what that cost.
    static let workspaceWindowID = "workspace"

    var body: some Scene {
        // Keyed on the workspace path, which does three things at once: each
        // window gets its own identity for state restoration, `openWindow`
        // raises the window already showing a path instead of making a second
        // one, and a window remembers which workspace it had across launches.
        WindowGroup(id: Self.workspaceWindowID, for: String.self) { $path in
            WorkspaceWindow(path: $path)
        }
        .windowToolbarStyle(.unified)
        .commands { VBXCommands() }

        // Its own window rather than a sheet: the tutorial is meant to be read
        // beside the app, not instead of it.
        WindowGroup(id: "tutorial", for: String.self) { $section in
            TutorialWindow(section: section)
        }
        .defaultSize(width: 860, height: 600)

        // One window for the app, not one per workspace: it names the app.
        Window("About Visual Beads", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsWindow()
        }
    }
}

/// One window, one workspace.
///
/// The store lives here rather than on the `App` — that is the whole of what
/// makes several workspaces open at once. `WindowGroup` already made multiple
/// windows; they were simply all rendering one store, so opening a folder in
/// either changed both.
///
/// ``ProjectStore`` was already shaped for this: it is documented as state for
/// *one* workspace and holds nothing static, so nothing had to be untangled to
/// give each window its own.
struct WorkspaceWindow: View {
    /// The workspace this window shows. Written back so the scene remembers it.
    @Binding var path: String?

    @StateObject private var store = ProjectStore()
    @State private var showingExportWizard = false

    var body: some View {
        ContentView()
            .environmentObject(store)
            .frame(minWidth: 1000, minHeight: 620)
            // Publishes this window's store to the menu bar. The menu is
            // app-wide but its commands are not: every one of them acts on the
            // key window's workspace, and a menu item that silently acted on
            // the wrong window would be worse than one that is disabled.
            .focusedSceneValue(\.projectStore, store)
            .task {
                if let path {
                    // Not `open(path:)`: a restored window's workspace is not
                    // something the user chose this launch, so one that has
                    // since moved lands in the neutral empty state instead of
                    // reporting an error nobody asked for.
                    await store.openRestoredWorkspace(path: path)
                } else {
                    await store.openInitialWorkspace()
                    // Record what the window landed on, so reopening it later
                    // returns to the same workspace.
                    path = store.info.map { workspaceRoot(of: $0.source) } ?? nil
                }
            }
            // vbx://open?workspace=...&bead=... — the same shape the inspector's
            // inline bead links use, so one handler serves links from inside and
            // outside the app.
            .onOpenURL { url in
                Task { await store.open(url: url) }
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let info = activity.userInfo else { return }
                _ = store.openSpotlightItem(info)
            }
            .sheet(isPresented: $showingExportWizard) {
                ExportWizard().environmentObject(store)
            }
            .focusedSceneValue(\.exportWizardPresented, $showingExportWizard)
    }

    /// `<workspace>/.beads/issues.jsonl` → `<workspace>`.
    private func workspaceRoot(of source: String) -> String {
        URL(fileURLWithPath: source)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }
}

/// The tutorial, with a store of its own.
///
/// It reads `surface` to highlight the section matching the current view. With
/// per-window stores there is no single "the" workspace to read that from, and
/// a tutorial that follows whichever window was last focused would jump around
/// while being read. Its own store keeps it still.
struct TutorialWindow: View {
    let section: String?
    @StateObject private var store = ProjectStore()

    var body: some View {
        TutorialView(initialSection: section)
            .environmentObject(store)
    }
}

/// Settings act on the key window's workspace.
///
/// Both toggles are stored per workspace today, so with several windows open
/// they need a subject. The focused window is that subject; with none, the form
/// says so rather than binding to nothing.
struct SettingsWindow: View {
    @FocusedValue(\.projectStore) private var store: ProjectStore?

    var body: some View {
        if let store {
            SettingsView().environmentObject(store)
        } else {
            Text("Open a workspace window to change its settings.")
                .foregroundStyle(.secondary)
                .frame(width: 460, height: 260)
        }
    }
}

// MARK: - Focused values

/// The key window's store, for the menu bar to act on.
private struct ProjectStoreKey: FocusedValueKey {
    typealias Value = ProjectStore
}

/// The key window's export-wizard presentation, so File ▸ Export opens the
/// sheet on the window the user is looking at.
private struct ExportWizardKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var projectStore: ProjectStore? {
        get { self[ProjectStoreKey.self] }
        set { self[ProjectStoreKey.self] = newValue }
    }

    var exportWizardPresented: Binding<Bool>? {
        get { self[ExportWizardKey.self] }
        set { self[ExportWizardKey.self] = newValue }
    }
}

/// Menu-bar commands. Every action lives here first so it gets a real macOS
/// shortcut, and the UI calls the same store methods.
///
/// Everything acts on ``FocusedValues/projectStore`` — the key window's store —
/// rather than a captured one, because the menu bar is app-wide while the
/// workspaces are not.
struct VBXCommands: Commands {
    @FocusedValue(\.projectStore) private var store: ProjectStore?
    @FocusedValue(\.exportWizardPresented) private var exportWizardPresented: Binding<Bool>?
    @ObservedObject private var recents = RecentWorkspaces.shared
    @Environment(\.openWindow) private var openWindow

    /// The last few workspaces, most recent first.
    ///
    /// App-wide rather than per-window: where you have been is a property of
    /// the person, not of one window, and the list is backed by a single
    /// preferences key. Opening one raises the window already showing it.
    @ViewBuilder
    private var recentWorkspacesMenu: some View {
        Menu("Recent Workspaces") {
            ForEach(recents.entries) { entry in
                Button(entry.name) { openWindow(value: entry.path) }
                    .help(entry.path)
            }
            Divider()
            Button("Clear Menu") { recents.clear() }
                .disabled(recents.entries.isEmpty)
        }
        .disabled(recents.entries.isEmpty)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // A window with no workspace yet; it opens the panel itself.
            //
            // By **id**, not by value. This was `openWindow(value: String?.none)`
            // and did nothing at all: `openWindow(value:)` is generic over any
            // `Codable & Hashable`, so `String?` compiles happily — and then
            // SwiftUI resolves the scene by the *type* of that value. The group
            // is declared `for: String.self`; nothing declares `String?`, so no
            // scene matched and no window opened. Silently, because a call that
            // finds no scene is not an error.
            //
            // The recents menu below never had the problem: it passes a plain
            // `String`, which is why one route worked and the other did not.
            Button("New Window") { openWindow(id: VBXApp.workspaceWindowID) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open Workspace…") { store?.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store == nil)
            recentWorkspacesMenu
            Button("Reload") { Task { await store?.reload(force: true) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store?.isLoaded != true)
            Divider()
            Button("Export Markdown Report…") { Task { await store?.exportMarkdown() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store?.isLoaded != true)
            Button("Export Static Site…") { exportWizardPresented?.wrappedValue = true }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(store?.isLoaded != true || exportWizardPresented == nil)
            Divider()
            Button("Install Command Line Tool…") { installCommandLineTool() }
                .disabled(!CommandLineTool.isAvailable)
        }

        CommandMenu("View") {
            // The same list the toolbar and the sidebar read, so a command
            // cannot switch to a surface neither of them offers. Without a
            // store there is nothing open and nothing to hide.
            ForEach(store?.availableSurfaces ?? ViewSurface.allCases) { surface in
                Button(surface.displayName) { store?.surface = surface }
                    .keyboardShortcut(surface.keyEquivalent, modifiers: .command)
                    .disabled(store == nil)
            }
            Divider()
            ForEach(IssueFilter.allCases) { filter in
                Button("Filter: \(filter.displayName)") { store?.query.filter = filter }
                    .disabled(store == nil)
            }
            Divider()
            Button("Compute Full Metrics") { Task { await store?.computePhase2() } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(store?.metrics.hasPhase2Values != false || store?.isLoaded != true)
        }

        // Replaces the standard About panel, whose credits field is a poor
        // place for several thousand lines of licence text.
        CommandGroup(replacing: .appInfo) {
            Button("About Visual Beads") { openWindow(id: "about") }
        }

        CommandGroup(replacing: .help) {
            Button("vbx Tutorial") { openWindow(id: "tutorial", value: "welcome") }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

extension VBXCommands {
    /// Links the bundled `vbx-cli` somewhere on the user's PATH.
    ///
    /// The destination comes from a save panel because, under the App Sandbox,
    /// that grant is the only thing authorising the write — a hardcoded
    /// `/usr/local/bin` would simply fail.
    fileprivate func installCommandLineTool() {
        let alert = NSAlert()
        switch CommandLineTool.install() {
        case .installed(let path):
            alert.messageText = "Command line tool installed"
            alert.informativeText = "vbx-cli is linked at \(path)."
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Could not install the command line tool"
            alert.informativeText = message
        case .cancelled:
            return
        }
        alert.runModal()
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        Form {
            Section("Keyboard") {
                Toggle("Terminal keys (bv single-key shortcuts)", isOn: $store.terminalKeysEnabled)
                Text(
                    "When on, bv's bindings — j/k, o/r/c/a, b/i/g/E — work whenever "
                        + "no text field has focus. Menu shortcuts always work."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            DeployCredentialsSettings()
            Section("Analysis") {
                Toggle("Skip expensive metrics on open", isOn: $store.skipPhase2)
                Text(
                    "Skips PageRank, betweenness, HITS and cycle detection. "
                        + "They can still be computed on demand."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 260)
    }
}
