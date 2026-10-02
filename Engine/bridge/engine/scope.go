package engine

import (
	"encoding/json"
	"fmt"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/recipe"
)

// bv 0.25.2's --label and --recipe are global scopes, not per-command
// filters. Its scopeLoadedIssues (cmd/bv/main.go) runs once, before any robot
// handler:
//
//   - --label swaps the loaded issues for the label subgraph's AllIssues — the
//     labelled beads plus their direct dependency neighbours — and makes the
//     labelled CoreIssues the candidates, the beads a command may recommend.
//     An unknown label is an empty selection that still carries its envelope.
//   - --recipe then runs recipe.Apply over the candidates (every issue when
//     there is no label), and the issues become exactly what it selected, in
//     its order, max_items cut included. The label's neighbours are dropped:
//     under both flags the analysis set is the recipe's selection of the
//     labelled beads. The recipe's metrics are taken over the whole source.
//
// Every handler then analyses that set afresh through RobotContext.Analyzer,
// while the envelope keeps the unscoped data hash, names the flags in `scope`
// — the recipe as it was given, a path included — and hashes the candidates
// into scope_hash.
//
// vbx ports that one step here, and every scope-aware method reads its issues,
// analyzer and provenance scope from it, so no command carries its own copy of
// the rule. bv exports no function doing the selection, which is why it is
// ported rather than called; the recipe itself is applied by bv's own
// recipe.Apply.

// scopeRequest is the scope every scope-aware method accepts: bv's --label
// and --recipe. Request structs embed it, so the JSON keys are the same
// everywhere.
type scopeRequest struct {
	Label string `json:"label"`
	// Recipe is a recipe name or a .yaml/.yml path, resolved as bv resolves
	// --recipe (resolveRecipe).
	Recipe string `json:"recipe"`
}

// robotView is the issue set a robot method answers over.
type robotView struct {
	// issues is the analysis set: the session's visible beads, or the scoped
	// selection.
	issues []model.Issue
	// analyzer and stats are the session's own when unscoped, and built
	// afresh over issues when scoped; scoped stats have finished Phase 2.
	analyzer *analysis.Analyzer
	stats    *analysis.GraphStats
	// candidates are the beads a command may recommend. Nil means all of
	// issues; an empty map — an unknown label — means none.
	candidates map[string]bool
	// dataHash is the unscoped data hash in both cases, as bv's envelope
	// carries it.
	dataHash string
	// scope is the provenance scope behind scope_hash and the envelope's
	// `scope`.
	scope provenanceScope
}

// scoped reports whether a label or a recipe narrowed the view.
func (v robotView) scoped() bool { return v.scope.label != "" || v.scope.recipe != "" }

// wholeView is the session's whole analysis set, unscoped.
func (s *Session) wholeView() robotView {
	v, _ := s.view(scopeRequest{})
	return v
}

// view returns the session's analysis set under the request's scope, or the
// whole set when it names none. Only a recipe can fail: one that names no
// recipe, or a file that does not load, is bv's error.
func (s *Session) view(sc scopeRequest) (robotView, error) {
	issues, analyzer, stats := s.snapshot()
	v := robotView{issues: issues, analyzer: analyzer, stats: stats}
	if analyzer != nil {
		v.dataHash = analyzer.DataHash()
	}
	if sc.Label == "" && sc.Recipe == "" {
		return v, nil
	}

	scoped := issues
	var candidates map[string]bool
	if sc.Label != "" {
		subgraph := analysis.ComputeLabelSubgraph(issues, sc.Label)
		scoped = make([]model.Issue, 0, len(subgraph.AllIssues))
		for _, id := range subgraph.AllIssues {
			if issue, ok := subgraph.IssueMap[id]; ok {
				scoped = append(scoped, issue)
			}
		}
		candidates = make(map[string]bool, len(subgraph.CoreIssues))
		for _, id := range subgraph.CoreIssues {
			candidates[id] = true
		}
	}

	if sc.Recipe != "" {
		active, err := s.resolveRecipe(sc.Recipe)
		if err != nil {
			return robotView{}, err
		}
		selection := scoped
		if candidates != nil {
			selection = onlyCandidates(scoped, candidates)
		}
		// Capped, unlike recipe_apply: bv hands the recipe to Apply as it is.
		applied, err := recipe.Apply(selection, s.recipeMetrics(issues, active, stats), active, robotNow())
		if err != nil {
			return robotView{}, fmt.Errorf("recipe %s: %w", active.Name, err)
		}
		scoped = applied
	}

	// The scoped analyzer is this call's alone; the methods that read its
	// clock pin it through pinClock exactly as they pin the session's.
	an, st := s.analyse(scoped, s.readinessIndex(), candidates)
	st.WaitForPhase2()

	v.issues, v.analyzer, v.stats, v.candidates = scoped, an, st, candidates
	// scope_hash hashes the beads a command may pick from: the label's core,
	// narrowed to what the recipe selected.
	selected := make([]string, 0, len(scoped))
	for _, issue := range scoped {
		if candidates == nil || candidates[issue.ID] {
			selected = append(selected, issue.ID)
		}
	}
	v.scope = provenanceScope{label: sc.Label, recipe: sc.Recipe, candidates: selected}
	return v, nil
}

// seedHash is the data hash a triage may seed its analyzer with: only the
// unscoped one describes the issues it analyses, so a scoped view seeds
// nothing — bv's DataHashMatchesIssues.
func (v robotView) seedHash() string {
	if v.scoped() {
		return ""
	}
	return v.dataHash
}

// parseScopeRequest decodes the scope of a method that takes nothing else. A
// request that is absent or names no scope is the unscoped view.
func parseScopeRequest(req []byte) (scopeRequest, error) {
	var r scopeRequest
	if len(req) == 0 {
		return r, nil
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return r, err
	}
	return r, nil
}
