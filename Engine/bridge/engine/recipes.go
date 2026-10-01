package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/recipe"
	"gopkg.in/yaml.v3"
)

// Recipes: declarative view configuration.
//
// `pkg/recipe` loads, validates and — since bv 0.25 — applies them: recipe.Apply
// is the one engine bv's TUI and robot path share. vbx calls it rather than
// keeping a copy, because a recipe that selects different beads in vbx than in
// bv is worse than one that does not work at all, and the copy vbx used to
// keep did exactly that once bv moved `actionable` onto its readiness model
// (parent gating, future deferral, a missing blocker read as unknown).

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
	selected, err := applyRecipeTo(issues, found, s.recipeMetrics(issues, found, stats), robotNow())
	if err != nil {
		return nil, err
	}

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

	// bv's loader skips a recipe that fails Validate, with only a warning, so
	// one saved anyway would vanish from the list on the next load. Refusing
	// it here says why while the user still has the editor open.
	if err := r.Recipe.Validate(); err != nil {
		return nil, fmt.Errorf("recipe %q: %w", name, err)
	}

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

// applyRecipeTo filters and sorts with bv's own recipe.Apply, leaving the
// max_items cut to the caller so it can report how many matched.
//
// The analysis set goes in — tombstones are not candidates, as in bv — while
// metrics.Readiness carries the full-source authority, so `actionable` and
// `has_blockers` see a tombstoned blocker as resolved. A malformed time
// filter is an error, as it is in bv; the loader has normally rejected such a
// recipe already.
func applyRecipeTo(
	issues []model.Issue, r *recipe.Recipe, metrics recipe.Metrics, now time.Time,
) ([]model.Issue, error) {
	uncapped := *r
	uncapped.View.MaxItems = 0
	selected, err := recipe.Apply(issues, metrics, &uncapped, now)
	if err != nil {
		return nil, fmt.Errorf("recipe %s: %w", r.Name, err)
	}
	return selected, nil
}

// recipeMetrics supplies what the recipe's sort chain needs, as bv's
// recipeMetrics does: graph scores for pagerank/betweenness/impact, triage
// scores for triage. The graph scores are the session's own, waited for, so
// a Phase-2 sort is never silently a sort on zeros while Phase 2 is running.
func (s *Session) recipeMetrics(
	issues []model.Issue, r *recipe.Recipe, stats *analysis.GraphStats,
) recipe.Metrics {
	metrics := recipe.Metrics{Readiness: s.readinessIndex()}
	if r.NeedsGraphMetrics() && stats != nil {
		stats.WaitForPhase2()
		metrics.Graph = stats
	}
	if r.NeedsTriageScores() {
		scores := analysis.ComputeTriageScores(issues)
		metrics.Triage = make(map[string]float64, len(scores))
		for _, score := range scores {
			metrics.Triage[score.IssueID] = score.TriageScore
		}
	}
	return metrics
}
