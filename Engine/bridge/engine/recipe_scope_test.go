package engine

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// bv 0.25.2's --recipe is a global scope, as --label is: every scope-aware
// command answers over what the recipe selects — of the label's beads when
// both are given — and names the recipe in `scope` and scope_hash.
// Regression (vbx-7d5): vbx ignored --recipe outside --robot-recipe-apply, so
// --robot-triage --recipe actionable ranked all 10 open beads where bv ranks
// 3, with no scope in the envelope; and a recipe given by path was refused.
// The expected values are bv 0.25.2's over Fixtures/demo at
// SOURCE_DATE_EPOCH=1788000000.

const hubFirstRecipe = "name: hub-first\nfilters:\n  status: [open, in_progress, blocked]\n" +
	"sort:\n  field: pagerank\n  direction: desc\nview:\n  max_items: 4\n"

type scopedTriageShape struct {
	Meta struct {
		IssueCount int `json:"issue_count"`
	} `json:"meta"`
	Recommendations []struct {
		ID string `json:"id"`
	} `json:"recommendations"`
}

func (s scopedTriageShape) ids() string {
	out := make([]string, 0, len(s.Recommendations))
	for _, r := range s.Recommendations {
		out = append(out, r.ID)
	}
	return strings.Join(out, ",")
}

type recipeScopeShape struct {
	ScopeHash string `json:"scope_hash"`
	DataHash  string `json:"data_hash"`
	Scope     *struct {
		Label  string `json:"label"`
		Recipe string `json:"recipe"`
	} `json:"scope"`
}

func writeHubFirst(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "hub-first.yml")
	if err := os.WriteFile(path, []byte(hubFirstRecipe), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestRecipeScopedTriageRanksTheRecipesSelection(t *testing.T) {
	t.Setenv("SOURCE_DATE_EPOCH", "1788000000")
	s := openDemo(t)
	hub := writeHubFirst(t)

	for _, c := range []struct {
		req   map[string]any
		ids   string
		count int
	}{
		{map[string]any{"recipe": "actionable"}, "vbx-12,vbx-14,vbx-3", 3},
		{map[string]any{"recipe": "actionable", "label": "engine"}, "vbx-3", 1},
		// A path, loaded as bv's recipe.LoadFile does; its max_items cut
		// applies, and its PageRank sort reads the whole source's metrics.
		{map[string]any{"recipe": hub}, "vbx-3,vbx-12,vbx-4,vbx-7", 4},
		// With a label the recipe selects among the labelled beads only.
		{map[string]any{"recipe": hub, "label": "ui"}, "vbx-6,vbx-5,vbx-4,vbx-7", 4},
	} {
		got := call[scopedTriageShape](t, s, "triage", c.req)
		if got.ids() != c.ids || got.Meta.IssueCount != c.count {
			t.Errorf("triage %v: %s over %d issues, want bv's %s over %d",
				c.req, got.ids(), got.Meta.IssueCount, c.ids, c.count)
		}
	}
}

func TestRecipeScopeReachesEveryEnvelope(t *testing.T) {
	t.Setenv("SOURCE_DATE_EPOCH", "1788000000")
	s := openDemoFull(t)
	unscoped := call[recipeScopeShape](t, s, "suggest", nil)
	hub := writeHubFirst(t)
	// The path's hash includes the path as given, so it is computed here from
	// bv's selection rather than copied from a run in another directory.
	hubIDs := []string{"vbx-3", "vbx-12", "vbx-4", "vbx-7"}
	sort.Strings(hubIDs)

	for _, c := range []struct {
		label, recipe, hash string
	}{
		{"", "actionable", "79d68f58967a0eb368575694734763e77e5009c8b134cd6f28ab492e7f692fbe"},
		{"engine", "actionable", "046b1ce2055437e4619bb09e59db059bdcee3c18f91a2385c7dbb2c6fa022c40"},
		{"", hub, scopeHash("", hub, unscoped.DataHash, hubIDs)},
	} {
		req := map[string]any{"recipe": c.recipe}
		if c.label != "" {
			req["label"] = c.label
		}
		// Not capacity: bv stamps its envelope with the hash of the issues it
		// simulated, so its data_hash and scope_hash follow the scope.
		for _, method := range []string{"suggest", "priority", "next", "insights", "graph_export"} {
			got := call[recipeScopeShape](t, s, method, req)
			if got.Scope == nil || got.Scope.Recipe != c.recipe || got.Scope.Label != c.label {
				t.Errorf("%s %v: scope = %+v", method, req, got.Scope)
			}
			if got.ScopeHash != c.hash {
				t.Errorf("%s %v: scope_hash = %q, want bv's %q", method, req, got.ScopeHash, c.hash)
			}
			if got.DataHash != unscoped.DataHash {
				t.Errorf("%s %v: data_hash = %q, want the unscoped %q",
					method, req, got.DataHash, unscoped.DataHash)
			}
		}
	}
}

func TestRecipeScopedPlanOffersOnlyTheSelection(t *testing.T) {
	t.Setenv("SOURCE_DATE_EPOCH", "1788000000")
	s := openDemo(t)
	type planShape struct {
		Tracks []struct {
			Items []struct {
				ID string `json:"id"`
			} `json:"items"`
		} `json:"tracks"`
	}
	got := call[planShape](t, s, "plan", map[string]any{"recipe": "actionable", "label": "engine"})
	var ids []string
	for _, track := range got.Tracks {
		for _, item := range track.Items {
			ids = append(ids, item.ID)
		}
	}
	if strings.Join(ids, ",") != "vbx-3" {
		t.Errorf("plan offered %v, want only the recipe's selection of the label, vbx-3", ids)
	}
}

// An unknown recipe, or a path that does not load, is bv's error — not an
// unscoped answer.
func TestUnresolvableRecipeScopeIsAnError(t *testing.T) {
	s := openDemo(t)
	for _, method := range []string{"triage", "plan", "next", "insights", "suggest", "priority",
		"graph_export", "alerts", "capacity"} {
		if _, err := s.Call(method, []byte(`{"recipe":"no-such-recipe"}`)); err == nil ||
			err.Error() != `unknown recipe "no-such-recipe"` {
			t.Errorf("%s with an unknown recipe: err = %v, want bv's", method, err)
		}
		if _, err := s.Call(method, []byte(`{"recipe":"/no/such/recipe.yaml"}`)); err == nil ||
			!strings.Contains(err.Error(), "recipe file not found") {
			t.Errorf("%s with a missing recipe file: err = %v", method, err)
		}
	}
}

// recipe_apply and recipe_resolve take a path wherever they take a name,
// through the same resolution as the scope (resolveRecipe).
func TestRecipePathResolvesLikeAName(t *testing.T) {
	t.Setenv("SOURCE_DATE_EPOCH", "1788000000")
	s := openDemo(t)
	hub := writeHubFirst(t)

	// The beads bv's scope selects for this file; recipe_apply lists them in
	// the recipe's PageRank order.
	applied := call[recipeApplyShape](t, s, "recipe_apply", map[string]any{"name": hub})
	selected := append([]string{}, applied.IssueIDs...)
	sort.Strings(selected)
	if applied.Recipe.Name != "hub-first" || strings.Join(selected, ",") != "vbx-12,vbx-3,vbx-4,vbx-7" {
		t.Errorf("recipe_apply by path: %q selected %v", applied.Recipe.Name, applied.IssueIDs)
	}

	type resolution struct {
		Recipe *struct {
			Name string `json:"name"`
		} `json:"recipe"`
		Error     string `json:"error"`
		Available []struct {
			Name        string `json:"name"`
			Description string `json:"description"`
		} `json:"available"`
	}
	if got := call[resolution](t, s, "recipe_resolve", map[string]any{"name": hub}); got.Recipe == nil ||
		got.Recipe.Name != "hub-first" || got.Error != "" {
		t.Errorf("recipe_resolve by path: %+v", got)
	}
	unknown := call[resolution](t, s, "recipe_resolve", map[string]any{"name": "nope"})
	if unknown.Error != `unknown recipe "nope"` || unknown.Recipe != nil {
		t.Errorf("recipe_resolve unknown: %+v", unknown)
	}
	// bv lists the recipes it could have named, with their descriptions.
	listed := map[string]string{}
	for _, entry := range unknown.Available {
		listed[entry.Name] = entry.Description
	}
	if listed["actionable"] == "" {
		t.Errorf("recipe_resolve unknown: available = %v, want the built-ins described", listed)
	}
	missing := call[resolution](t, s, "recipe_resolve", map[string]any{"name": "/no/such.yaml"})
	if !strings.Contains(missing.Error, "recipe file not found") || len(missing.Available) != 0 {
		t.Errorf("recipe_resolve missing path: %+v", missing)
	}
}
