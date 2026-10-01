package engine

import (
	"encoding/json"
	"sort"
	"strings"
	"testing"
)

// bv 0.25.2's --label is one global scope applied before any robot handler
// runs. These pin each label-aware method to bv's answer over Fixtures/demo,
// for a known label, an unknown one and none. Regression (vbx-4cz): vbx-cli
// forwarded --label to the graph export only, so triage, plan, priority,
// next, suggest and insights answered unscoped — triage reported 18 issues
// for `engine` where bv reports 13 — with no scope in the envelope.

// openDemoFull opens the demo with Phase 2, for methods whose answer reads it.
func openDemoFull(t *testing.T) *Session {
	t.Helper()
	s, err := Open(OpenConfig{Path: demoFixturePath(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}

// bv 0.25.2's scope_hash over Fixtures/demo for each label scope.
var demoScopeHashes = map[string]string{
	"engine":        "88f4076acefdc8f314976afc1e6976ff486f93ad8b1cf0ab4f6cc171ab9935d3",
	"no-such-label": "85fc057df18aa3d60658b2d334a95bd6199b9ff848a59cdaed2b7ea92c8d589f",
}

func TestLabelScopedTriageRanksTheLabelSubgraph(t *testing.T) {
	s := openDemo(t)
	type triageShape struct {
		Meta struct {
			IssueCount int `json:"issue_count"`
		} `json:"meta"`
		Recommendations []struct {
			ID string `json:"id"`
		} `json:"recommendations"`
	}
	ids := func(got triageShape) string {
		out := make([]string, 0, len(got.Recommendations))
		for _, r := range got.Recommendations {
			out = append(out, r.ID)
		}
		return strings.Join(out, ",")
	}

	// bv 0.25.2: --robot-triage --label engine.
	got := call[triageShape](t, s, "triage", map[string]any{"label": "engine"})
	if got.Meta.IssueCount != 13 {
		t.Errorf("issue_count = %d, want bv's 13", got.Meta.IssueCount)
	}
	if ids(got) != "vbx-3,vbx-16,vbx-10" {
		t.Errorf("recommendations = %s, want bv's vbx-3,vbx-16,vbx-10", ids(got))
	}

	unknown := call[triageShape](t, s, "triage", map[string]any{"label": "no-such-label"})
	if unknown.Meta.IssueCount != 0 || len(unknown.Recommendations) != 0 {
		t.Errorf("unknown label: %d issues, %d recommendations, want none",
			unknown.Meta.IssueCount, len(unknown.Recommendations))
	}

	whole := call[triageShape](t, s, "triage", nil)
	if whole.Meta.IssueCount != 18 {
		t.Errorf("unscoped issue_count = %d, want the whole demo's 18", whole.Meta.IssueCount)
	}
}

func TestLabelScopedPlanOffersOnlyLabelledWork(t *testing.T) {
	s := openDemo(t)
	type planShape struct {
		TotalActionable int `json:"total_actionable"`
		Tracks          []struct {
			Items []struct {
				ID string `json:"id"`
			} `json:"items"`
		} `json:"tracks"`
	}

	// bv 0.25.2: --robot-plan --label engine plans vbx-3 alone.
	got := call[planShape](t, s, "plan", map[string]any{"label": "engine"})
	if got.TotalActionable != 1 || len(got.Tracks) != 1 || got.Tracks[0].Items[0].ID != "vbx-3" {
		t.Errorf("plan = %+v, want bv's single vbx-3", got)
	}
	unknown := call[planShape](t, s, "plan", map[string]any{"label": "no-such-label"})
	if unknown.TotalActionable != 0 || len(unknown.Tracks) != 0 {
		t.Errorf("unknown label plan = %+v, want empty", unknown)
	}
	if whole := call[planShape](t, s, "plan", nil); whole.TotalActionable != 3 {
		t.Errorf("unscoped total_actionable = %d, want 3", whole.TotalActionable)
	}
}

func TestLabelScopedPriorityIsComputedOverTheSubgraph(t *testing.T) {
	s := openDemoFull(t)
	type priorityShape struct {
		provenanceShape
		Recommendations []struct {
			IssueID string `json:"issue_id"`
			WhatIf  struct {
				DirectUnblocks int `json:"direct_unblocks"`
			} `json:"what_if"`
		} `json:"recommendations"`
		Summary struct {
			TotalIssues int `json:"total_issues"`
		} `json:"summary"`
	}

	// bv 0.25.2: --robot-priority --label engine — 13 issues, and vbx-3
	// unblocks 1 within the subgraph where it unblocks 6 project-wide.
	got := call[priorityShape](t, s, "priority", map[string]any{"label": "engine"})
	if got.Summary.TotalIssues != 13 {
		t.Errorf("total_issues = %d, want bv's 13", got.Summary.TotalIssues)
	}
	if len(got.Recommendations) == 0 || got.Recommendations[0].IssueID != "vbx-3" ||
		got.Recommendations[0].WhatIf.DirectUnblocks != 1 {
		t.Errorf("top recommendation = %+v, want bv's vbx-3 unblocking 1", got.Recommendations)
	}
	if got.ScopeHash != demoScopeHashes["engine"] || got.Scope == nil || got.Scope.Label != "engine" {
		t.Errorf("scope = %+v, scope_hash = %q, want bv's label scope", got.Scope, got.ScopeHash)
	}
}

// With nothing to recommend, recommendations is [], as bv writes it.
// Regression: an unknown label left the filtered slice nil, which encoded as
// null.
func TestUnknownLabelPriorityIsAnEmptyList(t *testing.T) {
	s := openDemoFull(t)
	out, err := s.Call("priority", []byte(`{"label":"no-such-label"}`))
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(out, &raw); err != nil {
		t.Fatal(err)
	}
	if string(raw["recommendations"]) != "[]" {
		t.Errorf("recommendations = %s, want bv's []", raw["recommendations"])
	}
}

// Every label-aware method with an envelope carries bv's scope and
// scope_hash, keeps the unscoped data hash, and carries no scope unscoped.
func TestLabelScopeReachesEveryEnvelope(t *testing.T) {
	s := openDemoFull(t)
	unscoped := call[provenanceShape](t, s, "suggest", nil)
	for _, method := range []string{"suggest", "priority", "next", "insights", "graph_export"} {
		if got := call[provenanceShape](t, s, method, nil); got.Scope != nil {
			t.Errorf("%s unscoped: scope = %+v, want none", method, got.Scope)
		}
		for label, hash := range demoScopeHashes {
			got := call[provenanceShape](t, s, method, map[string]any{"label": label})
			if got.Scope == nil || got.Scope.Label != label {
				t.Errorf("%s --label %s: scope = %+v", method, label, got.Scope)
			}
			if got.ScopeHash != hash {
				t.Errorf("%s --label %s: scope_hash = %q, want bv's %q",
					method, label, got.ScopeHash, hash)
			}
			if got.DataHash != unscoped.DataHash {
				t.Errorf("%s --label %s: data_hash = %q, want the unscoped %q",
					method, label, got.DataHash, unscoped.DataHash)
			}
		}
	}
}

func TestLabelScopedInsightsAreTheSubgraphsMetrics(t *testing.T) {
	s := openDemoFull(t)
	type insightsShape struct {
		FullStats struct {
			PageRank     map[string]float64 `json:"pagerank"`
			Articulation json.RawMessage    `json:"articulation_points"`
		} `json:"full_stats"`
	}

	got := call[insightsShape](t, s, "insights", map[string]any{"label": "engine"})
	ids := make([]string, 0, len(got.FullStats.PageRank))
	for id := range got.FullStats.PageRank {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	// bv 0.25.2: the engine subgraph's 13 beads.
	want := "vbx-1,vbx-10,vbx-11,vbx-12,vbx-15,vbx-16,vbx-2,vbx-3,vbx-4,vbx-5,vbx-6,vbx-7,vbx-8"
	if strings.Join(ids, ",") != want {
		t.Errorf("pagerank covers %v, want bv's %s", ids, want)
	}

	// An empty graph has no articulation points, which bv writes as null.
	unknown := call[insightsShape](t, s, "insights", map[string]any{"label": "no-such-label"})
	if string(unknown.FullStats.Articulation) != "null" {
		t.Errorf("articulation_points = %s, want bv's null", unknown.FullStats.Articulation)
	}
}

func TestLabelScopedSuggestDrawsFromTheSubgraph(t *testing.T) {
	s := openDemo(t)
	type suggestShape struct {
		Suggestions struct {
			Suggestions []json.RawMessage `json:"suggestions"`
		} `json:"suggestions"`
	}
	// bv 0.25.2: one suggestion under `engine`, none for an unknown label.
	if got := call[suggestShape](t, s, "suggest", map[string]any{"label": "engine"}); len(got.Suggestions.Suggestions) != 1 {
		t.Errorf("engine: %d suggestions, want bv's 1", len(got.Suggestions.Suggestions))
	}
	if got := call[suggestShape](t, s, "suggest", map[string]any{"label": "no-such-label"}); len(got.Suggestions.Suggestions) != 0 {
		t.Errorf("unknown label: %d suggestions, want none", len(got.Suggestions.Suggestions))
	}
}
