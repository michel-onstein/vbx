import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

private typealias Bead = VBXCore.Issue

/// bv's `naturalLess` for issue ids, used only to state the expected order.
private func naturalIDLess(_ a: String, _ b: String) -> Bool {
    func split(_ s: String) -> (String, Int)? {
        let digits = s.reversed().prefix(while: \.isNumber)
        guard !digits.isEmpty, let n = Int(String(digits.reversed())) else { return nil }
        return (String(s.dropLast(digits.count)), n)
    }
    if let (pa, na) = split(a), let (pb, nb) = split(b), pa == pb { return na < nb }
    return a < b
}

/// Recipes: declarative filter, sort and view, applied atomically.
@MainActor
@Suite("Recipes")
struct RecipeTests {

    @Test("The built-in recipes load")
    func builtinsLoad() async {
        let store = await Fixture.loadedStore()
        await store.loadRecipes()

        let names = store.recipes.recipes.map(\.recipe.name)
        // The two the bead calls out as worth having on day one.
        #expect(names.contains("actionable"))
        #expect(names.contains("high-impact"))
        #expect(store.recipes.builtins.count == store.recipes.recipes.count)
        #expect(store.recipes.userDefined.isEmpty)

        await store.close()
    }

    @Test("Applying a recipe replaces the filter and the sort")
    func applyingSetsEverything() async {
        let store = await Fixture.loadedStore()
        await store.loadRecipes()
        await store.applyRecipe(named: "actionable")

        #expect(store.activeRecipe?.name == "actionable")
        let visible = store.visibleIssues.map(\Bead.id)
        #expect(!visible.isEmpty)
        // The engine decides the selection and its order, so the visible list
        // is exactly what it returned.
        #expect(visible == store.recipeIDs)

        store.clearRecipe()
        #expect(store.activeRecipe == nil)
        #expect(store.recipeIDs == nil)

        await store.close()
    }

    @Test("An actionable recipe selects only unblocked beads")
    func actionableSelectsUnblocked() async {
        let store = await Fixture.loadedStore()
        await store.applyRecipe(named: "actionable")

        for id in store.recipeIDs ?? [] {
            #expect(store.actionable.contains(id), "\(id) is not actionable")
        }
        await store.close()
    }

    @Test("Search narrows within a recipe rather than discarding it")
    func searchNarrowsWithinRecipe() async {
        let store = await Fixture.loadedStore()
        await store.applyRecipe(named: "actionable")
        let before = store.visibleIssues.count

        store.query.searchText = "z-no-such-bead-z"
        // Losing the recipe on the first keystroke would be the wrong trade;
        // searching inside its results is the obvious thing to want.
        #expect(store.activeRecipe != nil)
        #expect(store.visibleIssues.count < before)

        store.query.searchText = ""
        #expect(store.visibleIssues.count == before)

        await store.close()
    }

    @Test("An unknown recipe leaves the present state alone")
    func unknownRecipe() async {
        let store = await Fixture.loadedStore()
        await store.applyRecipe(named: "no-such-recipe")
        #expect(store.activeRecipe == nil)
        #expect(store.recipeIDs == nil)
        await store.close()
    }

    // MARK: - Sort chain

    @Test("A nested sort chain round-trips without losing keys")
    func sortChainRoundTrip() throws {
        // bv models the chain as a linked list, which a Swift struct cannot
        // hold directly. Flattening must not drop the tail.
        let json = """
            {"field":"priority","direction":"asc",
             "secondary":{"field":"updated","direction":"desc",
             "secondary":{"field":"title"}}}
            """
        let sort = try JSONDecoder().decode(RecipeSort.self, from: Data(json.utf8))
        #expect(sort.keys.count == 3)
        #expect(sort.keys.map(\.field) == ["priority", "updated", "title"])
        #expect(sort.keys[1].isDescending)
        #expect(!sort.keys[2].isDescending)

        // And re-encoding rebuilds the nesting the engine expects.
        let encoded = try JSONEncoder().encode(sort)
        let again = try JSONDecoder().decode(RecipeSort.self, from: encoded)
        #expect(again.keys == sort.keys)
    }

    @Test("An empty sort encodes as nothing, not as a nameless field")
    func emptySortEncodesToNull() throws {
        let encoded = try JSONEncoder().encode(RecipeSort())
        let text = String(decoding: encoded, as: UTF8.self)
        // A `{"field":""}` block would read to the engine as an ordering by a
        // field called "", which sorts nothing but looks deliberate.
        #expect(text == "null")
    }

    @Test("A chain ending in an empty link stops there")
    func chainStopsAtEmptyLink() throws {
        let json = """
            {"field":"priority","secondary":{"direction":"desc"}}
            """
        let sort = try JSONDecoder().decode(RecipeSort.self, from: Data(json.utf8))
        // An empty link carries no ordering; following past it would invent one.
        #expect(sort.keys.map(\.field) == ["priority"])
    }

    // MARK: - Summaries

    @Test("A filter summary describes what it selects")
    func filterSummary() throws {
        let json = """
            {"status":["open"],"tags":["core","infra"],"exclude_tags":["docs"],
             "priority":[0,1],"actionable":true,"updated_after":"14d"}
            """
        let filters = try JSONDecoder().decode(RecipeFilters.self, from: Data(json.utf8))
        let summary = filters.summary
        #expect(summary.contains("open"))
        #expect(summary.contains("actionable"))
        #expect(summary.contains("+core"))
        #expect(summary.contains("−docs"))
        #expect(summary.contains("P0/1"))
        #expect(summary.contains("14d"))
    }

    @Test("An empty filter says so rather than reading as broken")
    func emptyFilterSummary() {
        #expect(RecipeFilters().summary == "everything")
    }

    @Test("Only unset fields are omitted when encoding")
    func encodingOmitsEmptyFields() throws {
        var filters = RecipeFilters()
        filters.tags = ["core"]
        let text = String(decoding: try JSONEncoder().encode(filters), as: UTF8.self)

        #expect(text.contains("tags"))
        // A saved recipe should read as what the user set, not as every field
        // they left alone.
        #expect(!text.contains("exclude_tags"))
        #expect(!text.contains("title_contains"))
    }

    @Test("A recipe round-trips through JSON")
    func recipeRoundTrip() throws {
        var recipe = Recipe(name: "mine", description: "my beads")
        recipe.filters.tags = ["core"]
        recipe.sort = RecipeSort(field: "priority", direction: "asc")
        recipe.view.maxItems = 20

        let encoded = try JSONEncoder().encode(recipe)
        let again = try JSONDecoder().decode(Recipe.self, from: encoded)

        #expect(again.name == "mine")
        #expect(again.filters.tags == ["core"])
        #expect(again.sort.field == "priority")
        #expect(again.view.maxItems == 20)
    }

    // MARK: - Saving

    @Test("A saved recipe becomes applicable, then removable")
    func saveAndDelete() async throws {
        // Writes into the workspace, so it gets a private copy of the fixture.
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.loadRecipes()

        var recipe = Recipe(name: "vbx-test-recipe", description: "temporary")
        recipe.sort = RecipeSort(field: "id", direction: "asc")
        await store.saveRecipe(recipe)

        #expect(
            store.recipes.userDefined.map(\.recipe.name).contains("vbx-test-recipe"),
            "save failed: \(store.loadError ?? "none")")

        await store.applyRecipe(named: "vbx-test-recipe")
        // bv 0.25's recipe.Apply sorts ids naturally — `x-2` before `x-10`
        // when the prefix matches, lexically otherwise — and vbx now applies
        // recipes with it rather than with its own lexical copy.
        let ids = store.recipeIDs ?? []
        #expect(!ids.isEmpty)
        #expect(ids == ids.sorted(by: naturalIDLess))

        await store.deleteRecipe(named: "vbx-test-recipe")
        let remaining = store.recipes.userDefined.map(\.recipe.name)
        #expect(
            !remaining.contains("vbx-test-recipe"),
            "still listed: \(remaining), error=\(store.loadError ?? "none")")
        #expect(store.activeRecipe == nil)

        await store.close()
    }

    /// Regression (vbx-7d5): the editor saved every recipe into
    /// `.bv/recipes.yaml`, where a recipe's own `.beads/recipes` file shadowed
    /// the copy — the edit looked lost, and delete could not remove it.
    @Test("Editing a .beads/recipes recipe changes its own file")
    func editProjectFileRecipe() async throws {
        let directory = try Fixture.copy()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recipes = directory.appendingPathComponent(".beads/recipes")
        try FileManager.default.createDirectory(at: recipes, withIntermediateDirectories: true)
        let file = recipes.appendingPathComponent("area.yaml")
        try "name: area\ndescription: One area\nfilters:\n  tags: [ui]\n"
            .write(to: file, atomically: true, encoding: .utf8)

        let store = ProjectStore()
        await store.open(path: directory.path)
        await store.loadRecipes()
        var recipe = try #require(
            store.recipes.userDefined.first { $0.recipe.name == "area" }?.recipe,
            "the project-file recipe is not listed")

        recipe.filters.tags = ["engine"]
        await store.saveRecipe(recipe)
        let saved = store.recipes.recipes.first { $0.recipe.name == "area" }?.recipe
        #expect(saved?.filters.tags == ["engine"], "the edit did not load: \(store.loadError ?? "none")")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("engine"))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".bv/recipes.yaml").path))

        await store.deleteRecipe(named: "area")
        #expect(!store.recipes.recipes.contains { $0.recipe.name == "area" })
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await store.close()
    }

    @Test("The sidebar renders its recipe section")
    func rendersSidebar() async throws {
        let store = await Fixture.loadedStore()
        await store.loadRecipes()

        let result = try Snapshot.render(
            SidebarView().environmentObject(store),
            name: "sidebar-recipes",
            size: CGSize(width: 240, height: 800)
        )
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }

    @Test("The recipe banner renders while one is applied")
    func rendersBanner() async throws {
        let store = await Fixture.loadedStore()
        await store.applyRecipe(named: "actionable")

        let result = try Snapshot.render(
            RecipeBanner().environmentObject(store).frame(width: 900),
            name: "recipe-banner",
            size: CGSize(width: 900, height: 40)
        )
        #expect(result.inkCoverage() > 0.005)
        await store.close()
    }
}
