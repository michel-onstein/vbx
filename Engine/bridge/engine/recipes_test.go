package engine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/recipe"
)

type recipeListShape struct {
	Path    string `json:"path"`
	Recipes []struct {
		Recipe struct {
			Name        string `json:"name"`
			Description string `json:"description"`
		} `json:"recipe"`
		IsBuiltin bool `json:"is_builtin"`
	} `json:"recipes"`
}

type recipeApplyShape struct {
	Recipe struct {
		Name string `json:"name"`
	} `json:"recipe"`
	IssueIDs  []string `json:"issue_ids"`
	Matched   int      `json:"matched"`
	Truncated bool     `json:"truncated"`
}

func TestRecipesIncludeTheBuiltIns(t *testing.T) {
	s := openFixture(t)
	list := call[recipeListShape](t, s, "recipes", nil)

	names := map[string]bool{}
	for _, entry := range list.Recipes {
		names[entry.Recipe.Name] = true
	}
	// The two the bead calls out as worth having on day one.
	for _, want := range []string{"actionable", "high-impact"} {
		if !names[want] {
			t.Errorf("built-in recipe %q is missing; got %v", want, keysOfBool(names))
		}
	}
	if list.Path == "" {
		t.Error("no recipe file path was reported")
	}
}

func TestApplyingActionableSelectsUnblockedBeads(t *testing.T) {
	s := openFixture(t)
	result := call[recipeApplyShape](t, s, "recipe_apply", map[string]any{"name": "actionable"})

	if result.Recipe.Name != "actionable" {
		t.Errorf("applied %q", result.Recipe.Name)
	}
	// In the fixture only c and d have no unresolved blocking dependency.
	got := map[string]bool{}
	for _, id := range result.IssueIDs {
		got[id] = true
	}
	for _, want := range []string{"c", "d"} {
		if !got[want] {
			t.Errorf("actionable did not select %q; got %v", want, result.IssueIDs)
		}
	}
	for _, unwanted := range []string{"a", "b"} {
		if got[unwanted] {
			t.Errorf("actionable selected the blocked bead %q", unwanted)
		}
	}
}

func TestApplyingAnUnknownRecipeIsAnError(t *testing.T) {
	s := openFixture(t)
	if _, err := s.Call("recipe_apply", []byte(`{"name":"nope"}`)); err == nil {
		t.Error("expected an error for an unknown recipe")
	}
	if _, err := s.Call("recipe_apply", nil); err == nil {
		t.Error("expected an error when no name is given")
	}
}

func TestUserRecipeRoundTrip(t *testing.T) {
	dir := newFixtureWorkspace(t)
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	var saved struct {
		Path string `json:"path"`
		Name string `json:"name"`
	}
	saved = call[struct {
		Path string `json:"path"`
		Name string `json:"name"`
	}](t, s, "recipe_save", map[string]any{
		"recipe": map[string]any{
			"name":        "infra-only",
			"description": "Just the infra beads",
			"filters":     map[string]any{"tags": []string{"infra"}},
			"sort":        map[string]any{"field": "id", "direction": "asc"},
		},
	})

	// bv's own location, so a recipe written here is one `bv --recipe` can
	// use rather than one only vbx can see.
	if filepath.Base(saved.Path) != "recipes.yaml" ||
		filepath.Base(filepath.Dir(saved.Path)) != ".bv" {
		t.Errorf("recipe written to %s, want <project>/.bv/recipes.yaml", saved.Path)
	}
	if _, err := os.Stat(saved.Path); err != nil {
		t.Fatalf("recipe file missing: %v", err)
	}

	// It is visible to the loader immediately, and applying it selects the
	// beads carrying that label.
	applied := call[recipeApplyShape](t, s, "recipe_apply", map[string]any{"name": "infra-only"})
	if len(applied.IssueIDs) != 2 {
		t.Errorf("infra-only selected %v, want c and e", applied.IssueIDs)
	}
	if applied.IssueIDs[0] != "c" || applied.IssueIDs[1] != "e" {
		t.Errorf("sort by id ascending produced %v", applied.IssueIDs)
	}

	call[struct{}](t, s, "recipe_delete", map[string]any{"name": "infra-only"})
	if _, err := s.Call("recipe_apply", []byte(`{"name":"infra-only"}`)); err == nil {
		t.Error("the deleted recipe is still applicable")
	}
	// Deleting one recipe must not remove the file, which holds the rest.
	if _, err := os.Stat(saved.Path); err != nil {
		t.Errorf("the recipe file was removed along with the recipe: %v", err)
	}
}

// A recipe defined by its own `.beads/recipes/<name>.yaml` — bv's
// project-file source, the highest precedence — is saved and deleted in that
// file. Regression (vbx-7d5): recipe_save wrote every recipe into
// .bv/recipes.yaml, where the project file shadowed the copy, so an edit made
// in the app changed nothing that loaded; and recipe_delete, which only read
// .bv/recipes.yaml, refused to delete it at all.
func TestProjectFileRecipeIsEditedInItsOwnFile(t *testing.T) {
	dir := newFixtureWorkspace(t)
	recipesDir := filepath.Join(dir, ".beads", "recipes")
	if err := os.MkdirAll(recipesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(recipesDir, "area.yaml")
	if err := os.WriteFile(file, []byte(
		"name: area\ndescription: One area\nfilters:\n  tags: [infra]\nsort:\n  field: id\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	before := call[recipeApplyShape](t, s, "recipe_apply", map[string]any{"name": "area"})
	if strings.Join(before.IssueIDs, ",") != "c,e" {
		t.Fatalf("the project-file recipe selected %v, want c,e", before.IssueIDs)
	}

	saved := call[struct {
		Path     string `json:"path"`
		Replaced bool   `json:"replaced"`
	}](t, s, "recipe_save", map[string]any{
		"recipe": map[string]any{
			"name":        "area",
			"description": "Another area",
			"filters":     map[string]any{"tags": []string{"core"}},
			"sort":        map[string]any{"field": "id", "direction": "asc"},
		},
	})
	if saved.Path != file || !saved.Replaced {
		t.Errorf("saved to %s (replaced %v), want the recipe's own %s", saved.Path, saved.Replaced, file)
	}
	if _, err := os.Stat(filepath.Join(dir, ".bv", "recipes.yaml")); !os.IsNotExist(err) {
		t.Errorf(".bv/recipes.yaml was written; the project file would shadow it (stat: %v)", err)
	}

	// The edit is what loads now, in vbx and — since it is the same file —
	// in bv.
	after := call[recipeApplyShape](t, s, "recipe_apply", map[string]any{"name": "area"})
	if strings.Join(after.IssueIDs, ",") != "a,b" {
		t.Errorf("after the edit the recipe selected %v, want a,b", after.IssueIDs)
	}
	reread, err := recipe.LoadFile(file)
	if err != nil {
		t.Fatalf("bv cannot load the rewritten file: %v", err)
	}
	if reread.Name != "area" || reread.Description != "Another area" {
		t.Errorf("rewritten file holds %q / %q", reread.Name, reread.Description)
	}

	call[struct{}](t, s, "recipe_delete", map[string]any{"name": "area"})
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Errorf("the recipe's file survived its deletion (stat: %v)", err)
	}
	if _, err := s.Call("recipe_apply", []byte(`{"name":"area"}`)); err == nil {
		t.Error("the deleted project-file recipe is still applicable")
	}
}

// A project-file recipe whose name differs from its file's stem is still
// found by name and written back to that file, not to one named after it.
func TestProjectFileRecipeIsFoundByNameNotFilename(t *testing.T) {
	dir := newFixtureWorkspace(t)
	recipesDir := filepath.Join(dir, ".beads", "recipes")
	if err := os.MkdirAll(recipesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(recipesDir, "sprint.yml")
	if err := os.WriteFile(file, []byte("name: sprint-review\nfilters:\n  tags: [docs]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	saved := call[struct {
		Path string `json:"path"`
	}](t, s, "recipe_save", map[string]any{
		"recipe": map[string]any{"name": "sprint-review", "filters": map[string]any{"tags": []string{"infra"}}},
	})
	if saved.Path != file {
		t.Errorf("saved to %s, want %s", saved.Path, file)
	}
	entries, _ := os.ReadDir(recipesDir)
	if len(entries) != 1 {
		t.Errorf("recipes directory holds %d files, want the one", len(entries))
	}
}

// Deleting a project-file recipe that .bv/recipes.yaml also defines clears
// both: removing the file alone would uncover the shadowed copy, and the
// recipe the user deleted would still be there.
func TestDeletingAProjectFileRecipeClearsItsShadowedCopy(t *testing.T) {
	dir := newFixtureWorkspace(t)
	recipesDir := filepath.Join(dir, ".beads", "recipes")
	if err := os.MkdirAll(recipesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(recipesDir, "area.yaml"),
		[]byte("name: area\nfilters:\n  tags: [infra]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, ".bv"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".bv", "recipes.yaml"),
		[]byte("recipes:\n  area:\n    name: area\n    filters:\n      tags: [core]\n  keep:\n    name: keep\n"),
		0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	call[struct{}](t, s, "recipe_delete", map[string]any{"name": "area"})
	if _, err := s.Call("recipe_apply", []byte(`{"name":"area"}`)); err == nil {
		t.Error("deleting the project file uncovered the .bv/recipes.yaml copy")
	}
	call[recipeApplyShape](t, s, "recipe_apply", map[string]any{"name": "keep"})
}

func TestRecipeNamesCannotEscapeTheDirectory(t *testing.T) {
	s := openFixture(t)
	// A silently sanitised name is a recipe the user cannot find again, so a
	// path-bearing name is refused outright.
	for _, name := range []string{"../escape", "nested/name", `back\slash`, "."} {
		req := []byte(`{"recipe":{"name":"` + name + `"}}`)
		if _, err := s.Call("recipe_save", req); err == nil {
			t.Errorf("accepted the recipe name %q", name)
		}
	}
}

// ---- filter and sort semantics --------------------------------------------

func recipeFixtureIssues() []model.Issue {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	return []model.Issue{
		{
			ID: "a", Title: "Alpha", Status: model.StatusOpen, Priority: 1,
			Labels:    []string{"core", "infra"},
			CreatedAt: base, UpdatedAt: base.AddDate(0, 0, 10),
		},
		{
			ID: "b", Title: "bravo", Status: model.StatusClosed, Priority: 0,
			Labels:    []string{"core"},
			CreatedAt: base.AddDate(0, 0, 5), UpdatedAt: base.AddDate(0, 0, 20),
		},
		{
			ID: "c", Title: "Charlie", Status: model.StatusOpen, Priority: 3,
			Labels: []string{"docs"},
		},
	}
}

// apply runs a recipe the way recipe_apply does, failing the test on error.
func apply(t *testing.T, issues []model.Issue, r *recipe.Recipe, now time.Time) []model.Issue {
	t.Helper()
	out, err := applyRecipeTo(issues, r, recipe.Metrics{}, now)
	if err != nil {
		t.Fatalf("applyRecipeTo: %v", err)
	}
	return out
}

func TestRecipeTagsRequireAllOfThem(t *testing.T) {
	issues := recipeFixtureIssues()

	// Both tags: only `a` carries them.
	both := apply(t, issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{Tags: []string{"core", "infra"}},
	}, time.Now())
	if len(both) != 1 || both[0].ID != "a" {
		t.Errorf("tags should require all of them, got %v", idsOf(both))
	}

	// One tag: `a` and `b`.
	one := apply(t, issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{Tags: []string{"core"}},
	}, time.Now())
	if len(one) != 2 {
		t.Errorf("single tag selected %v", idsOf(one))
	}
}

func TestRecipeExcludeTagsTakeAny(t *testing.T) {
	issues := recipeFixtureIssues()
	out := apply(t, issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{ExcludeTags: []string{"docs", "infra"}},
	}, time.Now())
	// Excluding is the mirror of including: carrying *any* forbidden tag is
	// enough to be dropped.
	if len(out) != 1 || out[0].ID != "b" {
		t.Errorf("exclude-tags kept %v", idsOf(out))
	}
}

func TestRecipeMatchingIsCaseInsensitive(t *testing.T) {
	issues := recipeFixtureIssues()
	out := apply(t, issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{Status: []string{"OPEN"}, Tags: []string{"CORE"}},
	}, time.Now())
	if len(out) != 1 || out[0].ID != "a" {
		t.Errorf("case-insensitive matching selected %v", idsOf(out))
	}
}

// TestRecipeDateFiltersKeepUndatedBeads is bv 0.25's rule, which reversed
// the one vbx's own copy kept: a bead with no timestamp is not excluded by a
// date filter.
func TestRecipeDateFiltersKeepUndatedBeads(t *testing.T) {
	issues := recipeFixtureIssues()
	now := time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC)

	out := apply(t, issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{UpdatedAfter: "20d"},
	}, now)
	// a was updated 2026-01-11, before the 2026-01-12 threshold; b on the
	// 21st; c has no timestamps at all.
	if got := idsOf(out); len(got) != 2 || got[0] != "b" || got[1] != "c" {
		t.Errorf("updated_after 20d selected %v, want [b c]", got)
	}
}

// TestRecipeUnparseableDateIsAnError: bv 0.25 reports a malformed time filter
// rather than skipping it, and so does recipe_apply.
func TestRecipeUnparseableDateIsAnError(t *testing.T) {
	_, err := applyRecipeTo(recipeFixtureIssues(), &recipe.Recipe{
		Name:    "bad-date",
		Filters: recipe.FilterConfig{CreatedAfter: "not-a-date"},
	}, recipe.Metrics{}, time.Now())
	if err == nil || !strings.Contains(err.Error(), "created_after") {
		t.Errorf("an unparseable date filter gave %v, want an error naming created_after", err)
	}
}

// TestSavingAnInvalidRecipeIsRefused: bv's loader skips a recipe that fails
// Validate, so saving one would write a recipe that silently never appears.
func TestSavingAnInvalidRecipeIsRefused(t *testing.T) {
	dir := newFixtureWorkspace(t)
	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	req := []byte(`{"recipe":{"name":"bad","filters":{"created_after":"yesterday-ish"}}}`)
	if _, err := s.Call("recipe_save", req); err == nil {
		t.Fatal("saved a recipe with an unparseable created_after")
	}
	if _, err := os.Stat(filepath.Join(dir, ".bv", "recipes.yaml")); !os.IsNotExist(err) {
		t.Errorf("a refused recipe still wrote the recipe file: %v", err)
	}
}

// TestRecipeActionableUsesTheReadinessAuthority: a bead blocked only by a
// tombstone is actionable, and its parent's readiness gates it — the two
// rules the old copy of the filter got wrong in opposite directions.
func TestRecipeActionableUsesTheReadinessAuthority(t *testing.T) {
	records := []model.Issue{
		{ID: "gone", Status: model.StatusTombstone},
		{ID: "after-gone", Status: model.StatusOpen, Dependencies: []*model.Dependency{
			{IssueID: "after-gone", DependsOnID: "gone", Type: model.DepBlocks}}},
		{ID: "blocker", Status: model.StatusOpen},
		{ID: "parent", Status: model.StatusOpen, Dependencies: []*model.Dependency{
			{IssueID: "parent", DependsOnID: "blocker", Type: model.DepBlocks}}},
		{ID: "child", Status: model.StatusOpen, Dependencies: []*model.Dependency{
			{IssueID: "child", DependsOnID: "parent", Type: model.DepParentChild}}},
	}
	actionable := true
	out, err := applyRecipeTo(visibleIssues(records), &recipe.Recipe{
		Filters: recipe.FilterConfig{Actionable: &actionable},
		Sort:    recipe.SortConfig{Field: "id"},
	}, recipe.Metrics{Readiness: readinessAuthority(records, nil)}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if got := idsOf(out); len(got) != 2 || got[0] != "after-gone" || got[1] != "blocker" {
		t.Errorf("actionable selected %v, want [after-gone blocker]", got)
	}
}

func TestRecipeSortUsesSecondaryThenID(t *testing.T) {
	issues := []model.Issue{
		{ID: "c", Title: "same", Priority: 1},
		{ID: "a", Title: "same", Priority: 1},
		{ID: "b", Title: "same", Priority: 0},
	}
	issues = apply(t, issues, &recipe.Recipe{
		Sort: recipe.SortConfig{
			Field:     "priority",
			Direction: "asc",
			Secondary: &recipe.SortConfig{Field: "title", Direction: "asc"},
		},
	}, time.Now())

	// b first on priority; a before c because the titles tie and ids break it.
	if got := idsOf(issues); got[0] != "b" || got[1] != "a" || got[2] != "c" {
		t.Errorf("sorted to %v", got)
	}
}

func TestRecipeSortDescending(t *testing.T) {
	issues := []model.Issue{
		{ID: "a", Priority: 0}, {ID: "b", Priority: 2}, {ID: "c", Priority: 1},
	}
	issues = apply(t, issues, &recipe.Recipe{
		Sort: recipe.SortConfig{Field: "priority", Direction: "desc"},
	}, time.Now())
	if got := idsOf(issues); got[0] != "b" || got[1] != "c" || got[2] != "a" {
		t.Errorf("descending sort produced %v", got)
	}
}

// TestRecipeMaxItemsIsReportedNotHidden: applyRecipeTo leaves the max_items
// cut to recipe_apply, which reports how many matched and that it truncated.
func TestRecipeMaxItemsIsReportedNotHidden(t *testing.T) {
	issues := recipeFixtureIssues()
	out := apply(t, issues, &recipe.Recipe{View: recipe.ViewConfig{MaxItems: 1}}, time.Now())
	if len(out) != len(issues) {
		t.Errorf("applyRecipeTo cut to %d beads; the cut belongs to recipe_apply", len(out))
	}
}

func idsOf(issues []model.Issue) []string {
	out := make([]string, 0, len(issues))
	for _, issue := range issues {
		out = append(out, issue.ID)
	}
	return out
}

func keysOfBool(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
