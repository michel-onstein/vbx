package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/recipe"
	"gopkg.in/yaml.v3"
)

// Recipes: declarative view configuration.
//
// `pkg/recipe` loads and merges them, but the code that *applies* one lives in
// `cmd/bv` and is not importable, so the filter and sort semantics are
// reproduced here. They are reproduced exactly, quirks included, because a
// recipe that selects different beads in vbx than in bv is worse than one that
// does not work at all.

// recipeLoader builds a loader scoped to the open workspace.
func (s *Session) recipeLoader() (*recipe.Loader, error) {
	dir := s.projectDir()
	if dir == "" {
		return nil, fmt.Errorf("session has no source")
	}
	loader := recipe.NewLoader(recipe.WithProjectDir(dir))
	if err := loader.Load(); err != nil {
		return nil, err
	}
	return loader, nil
}

// recipes lists every recipe, built-in and user-defined.
func (s *Session) recipes() ([]byte, error) {
	loader, err := s.recipeLoader()
	if err != nil {
		return nil, err
	}

	list := loader.List()
	entries := make([]map[string]any, 0, len(list))
	for _, r := range list {
		entries = append(entries, map[string]any{
			"recipe": r,
			// Where it came from decides whether it can be edited: a built-in
			// has no file to write back to.
			"source":     loader.Source(r.Name),
			"is_builtin": loader.Source(r.Name) == "" || loader.Source(r.Name) == "builtin",
		})
	}

	warnings := loader.Warnings()
	if warnings == nil {
		warnings = []string{}
	}
	return json.Marshal(map[string]any{
		"recipes":  entries,
		"warnings": warnings,
		"path":     s.recipeFilePath(),
	})
}

// recipeFilePath is where project recipes live.
//
// `<project>/.bv/recipes.yaml`, one file holding a map of them — bv's own
// location and format, so a recipe written here is a recipe `bv --recipe` can
// use. Writing to a vbx-specific path would have produced recipes only vbx
// could see.
func (s *Session) recipeFilePath() string {
	dir := s.projectDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, ".bv", "recipes.yaml")
}

// readRecipeFile loads the project's recipe file, or an empty one.
func readRecipeFile(path string) (*recipe.RecipeFile, error) {
	file := &recipe.RecipeFile{Recipes: map[string]*recipe.Recipe{}}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			// No file yet is the normal starting state.
			return file, nil
		}
		return nil, err
	}
	if err := yaml.Unmarshal(data, file); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	if file.Recipes == nil {
		file.Recipes = map[string]*recipe.Recipe{}
	}
	return file, nil
}

// writeRecipeFile saves the project's recipe file.
func writeRecipeFile(path string, file *recipe.RecipeFile) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", filepath.Dir(path), err)
	}
	encoded, err := yaml.Marshal(file)
	if err != nil {
		return fmt.Errorf("encoding recipes: %w", err)
	}
	if err := os.WriteFile(path, encoded, 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	return nil
}

type recipeRequest struct {
	Name string `json:"name"`
	// Recipe is the definition to save, for recipe_save.
	Recipe *recipe.Recipe `json:"recipe"`
}

// applyRecipe returns the beads a recipe selects, in the order it sorts them.
//
// Applying happens here rather than in Swift so that one implementation
// decides what a recipe means.
func (s *Session) applyRecipe(req []byte) ([]byte, error) {
	var r recipeRequest
	if len(req) == 0 {
		return nil, fmt.Errorf("recipe_apply requires a \"name\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	if r.Name == "" {
		return nil, fmt.Errorf("recipe_apply requires a non-empty \"name\"")
	}

	loader, err := s.recipeLoader()
	if err != nil {
		return nil, err
	}
	found := loader.Get(r.Name)
	if found == nil {
		return nil, fmt.Errorf("no recipe named %q", r.Name)
	}

	issues, _, stats := s.snapshot()
	selected := filterByRecipe(issues, found, robotNow())
	sortByRecipe(selected, found, stats)

	ids := make([]string, 0, len(selected))
	for _, issue := range selected {
		ids = append(ids, issue.ID)
	}

	// MaxItems caps what the recipe shows. The full count travels with it so
	// the UI can say the list is truncated rather than silently short.
	total := len(ids)
	if found.View.MaxItems > 0 && len(ids) > found.View.MaxItems {
		ids = ids[:found.View.MaxItems]
	}

	return json.Marshal(map[string]any{
		"recipe":    found,
		"issue_ids": ids,
		"matched":   total,
		"truncated": total > len(ids),
	})
}

// saveRecipe writes a user recipe into the workspace.
func (s *Session) saveRecipe(req []byte) ([]byte, error) {
	var r recipeRequest
	if len(req) == 0 {
		return nil, fmt.Errorf("recipe_save requires a \"recipe\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	if r.Recipe == nil || strings.TrimSpace(r.Recipe.Name) == "" {
		return nil, fmt.Errorf("recipe_save requires a recipe with a name")
	}

	// The name is the map key and the handle every command uses, so a name
	// that is only whitespace or a path fragment is refused rather than
	// sanitised — a silently renamed recipe is one the user cannot find again.
	name := strings.TrimSpace(r.Recipe.Name)
	if name == "" || strings.ContainsAny(name, `/\`) || name == "." || name == ".." {
		return nil, fmt.Errorf("%q is not a usable recipe name", name)
	}
	r.Recipe.Name = name

	path := s.recipeFilePath()
	if path == "" {
		return nil, fmt.Errorf("session has no source")
	}

	// Read-modify-write: the file holds every project recipe, so overwriting
	// it with just this one would delete the rest.
	file, err := readRecipeFile(path)
	if err != nil {
		return nil, err
	}
	_, replaced := file.Recipes[name]
	file.Recipes[name] = r.Recipe
	if err := writeRecipeFile(path, file); err != nil {
		return nil, err
	}

	return json.Marshal(map[string]any{
		"path": path, "name": name, "replaced": replaced,
	})
}

// deleteRecipe removes a project recipe.
func (s *Session) deleteRecipe(req []byte) ([]byte, error) {
	var r recipeRequest
	if len(req) == 0 || json.Unmarshal(req, &r) != nil || r.Name == "" {
		return nil, fmt.Errorf("recipe_delete requires a \"name\"")
	}

	path := s.recipeFilePath()
	if path == "" {
		return nil, fmt.Errorf("session has no source")
	}
	file, err := readRecipeFile(path)
	if err != nil {
		return nil, err
	}
	if _, found := file.Recipes[r.Name]; !found {
		// A built-in cannot be deleted, and neither can one that was never
		// there. Saying so beats silently succeeding.
		return nil, fmt.Errorf("no project recipe named %q", r.Name)
	}
	delete(file.Recipes, r.Name)
	if err := writeRecipeFile(path, file); err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{"removed": r.Name, "path": path})
}

// ---- filtering ------------------------------------------------------------

// filterByRecipe applies a recipe's filters, matching bv's semantics.
func filterByRecipe(issues []model.Issue, r *recipe.Recipe, now time.Time) []model.Issue {
	f := r.Filters

	// The blocker set is computed once: a bead is blocked when any blocking
	// dependency points at something not yet closed.
	openBlockers := map[string]bool{}
	if f.Actionable != nil || f.HasBlockers != nil {
		notClosed := map[string]bool{}
		for _, issue := range issues {
			if issue.Status != model.StatusClosed && issue.Status != model.StatusTombstone {
				notClosed[issue.ID] = true
			}
		}
		for _, issue := range issues {
			for _, dep := range issue.Dependencies {
				if dep == nil || !dep.Type.IsBlocking() {
					continue
				}
				if notClosed[dep.DependsOnID] {
					openBlockers[issue.ID] = true
					break
				}
			}
		}
	}

	// A date filter that will not parse is dropped rather than treated as the
	// zero time, which would exclude everything.
	createdAfter, hasCreatedAfter := parseRecipeTime(f.CreatedAfter, now)
	createdBefore, hasCreatedBefore := parseRecipeTime(f.CreatedBefore, now)
	updatedAfter, hasUpdatedAfter := parseRecipeTime(f.UpdatedAfter, now)
	updatedBefore, hasUpdatedBefore := parseRecipeTime(f.UpdatedBefore, now)

	out := make([]model.Issue, 0, len(issues))
	for _, issue := range issues {
		if len(f.Status) > 0 && !containsFold(f.Status, string(issue.Status)) {
			continue
		}
		if len(f.Priority) > 0 && !containsInt(f.Priority, issue.Priority) {
			continue
		}
		// Tags require *all* of them, unlike the label filter in the sidebar
		// which takes any. That is bv's rule and recipes are written to it.
		if len(f.Tags) > 0 && !hasAllLabels(issue.Labels, f.Tags) {
			continue
		}
		if len(f.ExcludeTags) > 0 && hasAnyLabel(issue.Labels, f.ExcludeTags) {
			continue
		}
		if f.TitleContains != "" &&
			!strings.Contains(strings.ToLower(issue.Title), strings.ToLower(f.TitleContains)) {
			continue
		}
		if f.IDPrefix != "" && !strings.HasPrefix(issue.ID, f.IDPrefix) {
			continue
		}
		if f.Actionable != nil && openBlockers[issue.ID] == *f.Actionable {
			continue
		}
		if f.HasBlockers != nil && openBlockers[issue.ID] != *f.HasBlockers {
			continue
		}

		// A bead with no timestamp is skipped by a date filter rather than
		// failing it: an unset date is unknown, not "the beginning of time".
		if hasCreatedAfter && !afterTime(issue.CreatedAt, createdAfter) {
			continue
		}
		if hasCreatedBefore && !beforeTime(issue.CreatedAt, createdBefore) {
			continue
		}
		if hasUpdatedAfter && !afterTime(issue.UpdatedAt, updatedAfter) {
			continue
		}
		if hasUpdatedBefore && !beforeTime(issue.UpdatedAt, updatedBefore) {
			continue
		}

		out = append(out, issue)
	}
	return out
}

func parseRecipeTime(value string, now time.Time) (time.Time, bool) {
	if strings.TrimSpace(value) == "" {
		return time.Time{}, false
	}
	parsed, err := recipe.ParseRelativeTime(value, now)
	if err != nil {
		return time.Time{}, false
	}
	return parsed, true
}

func afterTime(value time.Time, bound time.Time) bool {
	if value.IsZero() {
		return false
	}
	return value.After(bound)
}

func beforeTime(value time.Time, bound time.Time) bool {
	if value.IsZero() {
		return false
	}
	return value.Before(bound)
}

func containsFold(haystack []string, needle string) bool {
	for _, candidate := range haystack {
		if strings.EqualFold(candidate, needle) {
			return true
		}
	}
	return false
}

func containsInt(haystack []int, needle int) bool {
	for _, candidate := range haystack {
		if candidate == needle {
			return true
		}
	}
	return false
}

func hasAllLabels(labels []string, required []string) bool {
	for _, want := range required {
		if !containsFold(labels, want) {
			return false
		}
	}
	return true
}

func hasAnyLabel(labels []string, forbidden []string) bool {
	for _, want := range forbidden {
		if containsFold(labels, want) {
			return true
		}
	}
	return false
}

// ---- sorting --------------------------------------------------------------

// sortByRecipe orders in place, honouring the recipe's secondary key.
func sortByRecipe(issues []model.Issue, r *recipe.Recipe, stats interface {
	PageRank() map[string]float64
	Betweenness() map[string]float64
}) {
	if r.Sort.Field == "" {
		return
	}

	var pageRank, betweenness map[string]float64
	if stats != nil {
		pageRank = stats.PageRank()
		betweenness = stats.Betweenness()
	}

	sort.SliceStable(issues, func(i, j int) bool {
		if cmp := compareBy(issues[i], issues[j], r.Sort, pageRank, betweenness); cmp != 0 {
			return cmp < 0
		}
		if r.Sort.Secondary != nil {
			if cmp := compareBy(
				issues[i], issues[j], *r.Sort.Secondary, pageRank, betweenness); cmp != 0 {
				return cmp < 0
			}
		}
		// Ids last, so an ordering is reproducible rather than dependent on
		// the input order.
		return issues[i].ID < issues[j].ID
	})
}

// compareBy returns -1, 0 or 1 for one sort key, direction applied.
func compareBy(
	a, b model.Issue, config recipe.SortConfig, pageRank, betweenness map[string]float64,
) int {
	result := 0
	switch strings.ToLower(config.Field) {
	case "priority":
		result = compareInt(a.Priority, b.Priority)
	case "id":
		result = strings.Compare(a.ID, b.ID)
	case "title":
		result = strings.Compare(strings.ToLower(a.Title), strings.ToLower(b.Title))
	case "created":
		result = compareTime(a.CreatedAt, b.CreatedAt)
	case "updated":
		result = compareTime(a.UpdatedAt, b.UpdatedAt)
	case "pagerank":
		result = compareFloat(pageRank[a.ID], pageRank[b.ID])
	case "betweenness":
		result = compareFloat(betweenness[a.ID], betweenness[b.ID])
	default:
		return 0
	}

	if strings.EqualFold(config.Direction, "desc") {
		return -result
	}
	return result
}

func compareInt(a, b int) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

func compareFloat(a, b float64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

func compareTime(a, b time.Time) int {
	switch {
	case a.Before(b):
		return -1
	case a.After(b):
		return 1
	default:
		return 0
	}
}
