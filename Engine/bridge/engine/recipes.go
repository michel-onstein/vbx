package engine

import (
	"encoding/json"
	"errors"
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

// resolveRecipe turns a --recipe argument into a recipe exactly as bv does,
// through its recipe.Loader.Resolve: an argument ending .yaml or .yml is
// loaded from that path, anything else is looked up by name among the
// workspace's recipes. Every caller that takes a recipe argument — the scope,
// recipe_apply, export_report — resolves it here, so a path works wherever a
// name does. An unknown name is bv's *recipe.UnknownRecipeError.
func (s *Session) resolveRecipe(arg string) (*recipe.Recipe, error) {
	loader, err := s.recipeLoader()
	if err != nil {
		return nil, err
	}
	return loader.Resolve(arg)
}

// recipeResolution is what recipe_resolve reports: the recipe, or bv's
// error with what bv prints beside it.
type recipeResolution struct {
	Recipe *recipe.Recipe `json:"recipe,omitempty"`
	// Error is bv's message, which it prints after "Error: ".
	Error string `json:"error,omitempty"`
	// Warnings are the loader's, which bv prints after a failed resolution
	// because a project recipe file that did not parse explains an unknown
	// name.
	Warnings []string `json:"warnings,omitempty"`
	// Available lists the recipes, by name, when the argument named none.
	Available []recipe.RecipeSummary `json:"available,omitempty"`
}

// resolveRecipeCall resolves a recipe argument without applying it, so
// vbx-cli can refuse an unknown recipe the way bv does — before any command
// runs, with the recipes it could have named. A failed resolution is a
// result, not an engine error, because the caller needs the list as well as
// the message.
func (s *Session) resolveRecipeCall(req []byte) ([]byte, error) {
	var r recipeRequest
	if len(req) == 0 || json.Unmarshal(req, &r) != nil || r.Name == "" {
		return nil, fmt.Errorf("recipe_resolve requires a \"name\"")
	}
	loader, err := s.recipeLoader()
	if err != nil {
		return nil, err
	}
	resolved, err := loader.Resolve(r.Name)
	if err == nil {
		return json.Marshal(recipeResolution{Recipe: resolved})
	}
	out := recipeResolution{Error: err.Error(), Warnings: loader.Warnings()}
	var unknown *recipe.UnknownRecipeError
	if errors.As(err, &unknown) {
		for _, name := range unknown.Available {
			summary := recipe.RecipeSummary{Name: name}
			if found := loader.Get(name); found != nil {
				summary.Description = found.Description
			}
			out.Available = append(out.Available, summary)
		}
	}
	return json.Marshal(out)
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

	found, err := s.resolveRecipe(r.Name)
	if err != nil {
		return nil, err
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

	// A recipe defined by its own .beads/recipes file is written back there.
	// That file outranks .bv/recipes.yaml in bv's precedence, so a copy saved
	// into the map would be shadowed and the edit would change nothing that
	// loads, in vbx or in bv.
	own, err := s.projectFileRecipe(name)
	if err != nil {
		return nil, err
	}
	if own != "" {
		if err := writeRecipeYAML(own, r.Recipe); err != nil {
			return nil, err
		}
		return json.Marshal(map[string]any{"path": own, "name": name, "replaced": true})
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

	// Both project sources are cleared: deleting only the project file would
	// uncover a same-named copy in .bv/recipes.yaml, and the recipe the user
	// deleted would still be there.
	own, err := s.projectFileRecipe(r.Name)
	if err != nil {
		return nil, err
	}
	if own != "" {
		if err := os.Remove(own); err != nil {
			return nil, fmt.Errorf("removing %s: %w", own, err)
		}
	}

	path := s.recipeFilePath()
	if path == "" {
		return nil, fmt.Errorf("session has no source")
	}
	file, err := readRecipeFile(path)
	if err != nil {
		return nil, err
	}
	if _, found := file.Recipes[r.Name]; found {
		delete(file.Recipes, r.Name)
		if err := writeRecipeFile(path, file); err != nil {
			return nil, err
		}
	} else if own == "" {
		// A built-in cannot be deleted, and neither can one that was never
		// there. Saying so beats silently succeeding.
		return nil, fmt.Errorf("no project recipe named %q", r.Name)
	} else {
		path = own
	}
	return json.Marshal(map[string]any{"removed": r.Name, "path": path})
}

// projectFileRecipe returns the .beads/recipes file that defines name, or ""
// when no project file does. bv's loader decides, so a file whose stem is not
// the recipe's name is still found by the name inside it.
func (s *Session) projectFileRecipe(name string) (string, error) {
	loader, err := s.recipeLoader()
	if err != nil {
		return "", err
	}
	if loader.Source(name) != recipe.SourceProjectFile {
		return "", nil
	}
	return loader.Path(name), nil
}

// writeRecipeYAML saves one recipe as a single-recipe file, the shape bv's
// recipe.LoadFile reads from .beads/recipes.
func writeRecipeYAML(path string, r *recipe.Recipe) error {
	encoded, err := yaml.Marshal(r)
	if err != nil {
		return fmt.Errorf("encoding recipe %s: %w", r.Name, err)
	}
	if err := os.WriteFile(path, encoded, 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	return nil
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
// A session that skips Phase 2 has no PageRank or betweenness at all, so it
// analyses afresh, as bv always does for a recipe that sorts on them —
// capacity makes the same choice for the same reason.
func (s *Session) recipeMetrics(
	issues []model.Issue, r *recipe.Recipe, stats *analysis.GraphStats,
) recipe.Metrics {
	metrics := recipe.Metrics{Readiness: s.readinessIndex()}
	if r.NeedsGraphMetrics() {
		if s.config.SkipPhase2 || stats == nil {
			an := analysis.NewAnalyzer(issues)
			an.SetNow(robotNow())
			full := an.Analyze()
			stats = &full
		}
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
