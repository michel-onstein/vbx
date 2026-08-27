import VBXAppCore
import VBXCore
import SwiftUI

/// The sidebar's recipe list.
///
/// Applying one sets filter, sort and view together — that is what a recipe
/// is — so it sits beside the filters rather than inside them.
struct SidebarRecipesSection: View {
    @EnvironmentObject var store: ProjectStore
    /// What the editor is editing — and, by being non-nil, that it is open.
    ///
    /// One piece of state, not a value plus a flag: `sheet(isPresented:)`
    /// captures its content closure from the view as it stood *before* the
    /// button's write landed, so a companion `editing` still reads nil when the
    /// sheet is built and the window opens empty. It stays empty until some
    /// unrelated change re-runs this body — around twenty seconds in a live
    /// app, and forever in one nothing else is touching. `sheet(item:)` hands
    /// the content the value that triggered it, so there is nothing to be stale.
    /// See BUGS.md, 2026-08-24.
    @State private var editing: Recipe?

    var body: some View {
        Section("Recipes") {
            if store.activeRecipe != nil {
                Button {
                    store.clearRecipe()
                } label: {
                    HStack {
                        Label("Clear recipe", systemImage: "xmark.circle")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(store.recipes.recipes) { entry in
                row(entry)
            }

            Button {
                // A new recipe starts from whatever is on screen, which is
                // usually why someone wants to save one.
                editing = Recipe(name: "", description: "")
            } label: {
                HStack {
                    Label("New recipe…", systemImage: "plus")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { recipe in
            RecipeEditor(recipe: recipe) { saved in
                Task { await store.saveRecipe(saved) }
            }
        }
    }

    private func row(_ entry: RecipeEntry) -> some View {
        let isActive = store.activeRecipe?.name == entry.recipe.name

        return Button {
            Task { await store.applyRecipe(named: entry.recipe.name) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "square.stack.3d.up")
                    .font(.caption)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.recipe.name)
                    Text(
                        entry.recipe.description.isEmpty
                            ? entry.recipe.filters.summary : entry.recipe.description
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : .primary)
        .contextMenu {
            // A built-in has no file to write back to, so it can be copied
            // but not edited in place.
            Button(entry.isBuiltin ? "Duplicate…" : "Edit…") {
                var copy = entry.recipe
                if entry.isBuiltin { copy.name = "\(entry.recipe.name)-copy" }
                editing = copy
            }
            if !entry.isBuiltin {
                Button("Delete", role: .destructive) {
                    Task { await store.deleteRecipe(named: entry.recipe.name) }
                }
            }
        }
    }
}

/// Form editor for a project recipe.
struct RecipeEditor: View {
    @State var recipe: Recipe
    let onSave: (Recipe) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var tagsText = ""
    @State private var excludeTagsText = ""
    @State private var statusText = ""

    private static let statuses = [
        "open", "in_progress", "blocked", "review", "deferred", "closed",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(recipe.name.isEmpty ? "New recipe" : "Edit \(recipe.name)")
                .font(.headline)
                .padding(16)
            Divider()

            Form {
                Section("Identity") {
                    TextField("Name", text: $recipe.name)
                    TextField("Description", text: $recipe.description)
                }

                Section("Filters") {
                    TextField("Statuses (comma separated)", text: $statusText)
                    TextField("Must have all tags", text: $tagsText)
                    TextField("Exclude tags", text: $excludeTagsText)
                    TextField("Title contains", text: $recipe.filters.titleContains)
                    TextField("ID prefix", text: $recipe.filters.idPrefix)
                    // Relative forms like "14d" and "2w" are what bv accepts,
                    // and they keep a saved recipe meaningful over time.
                    TextField("Updated after (e.g. 14d)", text: $recipe.filters.updatedAfter)
                    TextField("Created after (e.g. 2w)", text: $recipe.filters.createdAfter)

                    Picker("Blocking", selection: blockingBinding) {
                        Text("Any").tag(0)
                        Text("Actionable only").tag(1)
                        Text("Blocked only").tag(2)
                    }
                }

                Section("Sort") {
                    Picker("Field", selection: sortFieldBinding) {
                        Text("(unsorted)").tag("")
                        ForEach(RecipeSort.fields, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Direction", selection: sortDirectionBinding) {
                        Text("Ascending").tag("asc")
                        Text("Descending").tag("desc")
                    }
                    .disabled(recipe.sort.isEmpty)
                    if recipe.sort.keys.count > 1 {
                        // The editor writes one key; a recipe with more keeps
                        // them, and this says so rather than silently
                        // discarding the rest on save.
                        Text("Also sorted by \(recipe.sort.keys.dropFirst().map(\.summary).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("View") {
                    Stepper(
                        "Show at most \(recipe.view.maxItems == 0 ? "all" : "\(recipe.view.maxItems)")",
                        value: $recipe.view.maxItems, in: 0...500, step: 5)
                    Toggle("Open the graph", isOn: $recipe.view.showGraph)
                    Toggle("Show metrics", isOn: $recipe.view.showMetrics)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(assembled())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recipe.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 620)
        .onAppear {
            tagsText = recipe.filters.tags.joined(separator: ", ")
            excludeTagsText = recipe.filters.excludeTags.joined(separator: ", ")
            statusText = recipe.filters.status.joined(separator: ", ")
        }
    }

    /// Folds the free-text fields back into the recipe.
    private func assembled() -> Recipe {
        var out = recipe
        out.name = out.name.trimmingCharacters(in: .whitespaces)
        out.filters.tags = splitList(tagsText)
        out.filters.excludeTags = splitList(excludeTagsText)
        out.filters.status = splitList(statusText)
        return out
    }

    private func splitList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Actionable and has-blockers are two spellings of one choice, so the
    /// editor offers one control and writes whichever field it needs.
    private var blockingBinding: Binding<Int> {
        Binding(
            get: {
                if recipe.filters.actionable == true { return 1 }
                if recipe.filters.actionable == false || recipe.filters.hasBlockers == true {
                    return 2
                }
                return 0
            },
            set: { choice in
                switch choice {
                case 1:
                    recipe.filters.actionable = true
                    recipe.filters.hasBlockers = nil
                case 2:
                    recipe.filters.actionable = false
                    recipe.filters.hasBlockers = nil
                default:
                    recipe.filters.actionable = nil
                    recipe.filters.hasBlockers = nil
                }
            })
    }

    private var sortFieldBinding: Binding<String> {
        Binding(
            get: { recipe.sort.field },
            set: { field in
                guard !field.isEmpty else {
                    recipe.sort = RecipeSort()
                    return
                }
                var keys = recipe.sort.keys
                if keys.isEmpty {
                    keys = [RecipeSortKey(field: field)]
                } else {
                    keys[0].field = field
                }
                recipe.sort = RecipeSort(keys: keys)
            })
    }

    private var sortDirectionBinding: Binding<String> {
        Binding(
            get: { recipe.sort.direction.isEmpty ? "asc" : recipe.sort.direction },
            set: { direction in
                guard !recipe.sort.keys.isEmpty else { return }
                var keys = recipe.sort.keys
                keys[0].direction = direction
                recipe.sort = RecipeSort(keys: keys)
            })
    }
}

/// Banner shown while a recipe is applied.
struct RecipeBanner: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        if let recipe = store.activeRecipe {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.accentColor)
                Text(recipe.name).font(.caption.weight(.medium))
                Text(recipe.filters.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !recipe.sort.isEmpty {
                    Text("sorted by \(recipe.sort.summary)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // Silent truncation would read as "this is everything".
                if store.recipeTruncated {
                    Text("showing the first \(recipe.view.maxItems)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Clear") { store.clearRecipe() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.1))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
