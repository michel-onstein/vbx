package engine

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// bv 0.25's search options, through the engine: the guaranteed exact-id hit
// and --search-min-score (vbx-52c). Both are bv's own code —
// VectorIndex.SearchTopKWithOptions — so these tests pin that vbx passes them
// through, not how bv implements them.

// exactIDWorkspace writes beads whose text is all about "zq 9", plus the bead
// actually called zq-9, whose id is drowned in a long unrelated description.
// Text similarity therefore ranks a decoy above it.
func exactIDWorkspace(t *testing.T) *Session {
	t.Helper()
	var lines []string
	record := func(id, title, description string) {
		lines = append(lines, fmt.Sprintf(
			`{"id":%q,"title":%q,"description":%q,"status":"open","issue_type":"task",`+
				`"priority":2,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}`,
			id, title, description))
	}
	for i := 1; i <= 6; i++ {
		record(fmt.Sprintf("dc-%d", i), "zq 9 zq 9 zq 9", "zq 9")
	}
	record("zq-9", "Quarterly invoice export",
		strings.Repeat("ledger reconciliation currency rounding statement archive ", 20))

	dir := t.TempDir()
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	content := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(filepath.Join(beads, "issues.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

type optionShape struct {
	MinScore *float64 `json:"min_score"`
	Results  []struct {
		IssueID   string   `json:"issue_id"`
		Score     float64  `json:"score"`
		TextScore *float64 `json:"text_score"`
		Title     string   `json:"title"`
	} `json:"results"`
}

func ids(shape optionShape) []string {
	out := make([]string, 0, len(shape.Results))
	for _, result := range shape.Results {
		out = append(out, result.IssueID)
	}
	return out
}

func TestExactIDQueryIsAHitEvenOutsideTheTextTopK(t *testing.T) {
	s := exactIDWorkspace(t)

	// The control: the same words, not spelled as the id, do not reach
	// zq-9 within the limit. Without it, the next assertion could pass on
	// text similarity alone — which is all vbx's old promotion handled.
	control := call[optionShape](t, s, "search", map[string]any{"query": "zq 9", "limit": 2})
	for _, id := range ids(control) {
		if id == "zq-9" {
			t.Fatalf("the fixture no longer buries zq-9: %v", ids(control))
		}
	}

	for _, mode := range []string{"text", "hybrid"} {
		got := call[optionShape](t, s, "search", map[string]any{
			"query": "zq-9", "limit": 2, "mode": mode,
		})
		if len(got.Results) == 0 || got.Results[0].IssueID != "zq-9" {
			t.Errorf("%s: an exact id query did not return that bead first: %v", mode, ids(got))
		}
		if len(got.Results) != 2 {
			t.Errorf("%s: the exact hit should replace the last candidate, not grow the list: %v",
				mode, ids(got))
		}
	}

	// An unambiguous case-folded id counts too, as in bv.
	folded := call[optionShape](t, s, "search", map[string]any{"query": "ZQ-9", "limit": 2})
	if len(folded.Results) == 0 || folded.Results[0].IssueID != "zq-9" {
		t.Errorf("a case-folded id query did not return the bead first: %v", ids(folded))
	}

	// An id no bead has guarantees nothing, and must not fail.
	unknown := call[optionShape](t, s, "search", map[string]any{"query": "zq-404", "limit": 2})
	for _, id := range ids(unknown) {
		if id == "zq-404" {
			t.Errorf("an unknown id produced a result: %v", ids(unknown))
		}
	}
}

func TestResultsCarryTitlesAsBvDoes(t *testing.T) {
	s := exactIDWorkspace(t)
	got := call[optionShape](t, s, "search", map[string]any{"query": "zq-9", "limit": 1})
	if len(got.Results) != 1 || got.Results[0].Title != "Quarterly invoice export" {
		t.Errorf("results carry no title: %+v", got.Results)
	}
}

func TestMinScoreDropsResultsBelowTheThreshold(t *testing.T) {
	s := openFixture(t)
	unfiltered := call[optionShape](t, s, "search", map[string]any{"query": "Charlie", "limit": 5})
	if unfiltered.MinScore != nil {
		t.Errorf("min_score echoed when none was given: %v", *unfiltered.MinScore)
	}
	if len(unfiltered.Results) < 2 {
		t.Fatalf("the fixture should give several results: %v", ids(unfiltered))
	}

	// A threshold between the best and the worst score keeps only the ones
	// at or above it. The fixture's titles are single words, so Charlie's
	// raw similarity is far above the rest and no lexical boost reorders them.
	best := unfiltered.Results[0].Score
	threshold := 0.5
	if best <= threshold {
		t.Fatalf("the best match scored %v; the threshold would drop everything", best)
	}
	got := call[optionShape](t, s, "search", map[string]any{
		"query": "Charlie", "limit": 5, "min_score": threshold,
	})
	if got.MinScore == nil || *got.MinScore != threshold {
		t.Errorf("min_score not echoed: %v", got.MinScore)
	}
	if len(got.Results) == 0 || len(got.Results) >= len(unfiltered.Results) {
		t.Errorf("threshold %v kept %v of %v", threshold, ids(got), ids(unfiltered))
	}
	for _, result := range got.Results {
		if result.Score < threshold {
			t.Errorf("%s scored %v, below the threshold %v", result.IssueID, result.Score, threshold)
		}
	}

	// The bounds are inclusive: -1 keeps everything.
	all := call[optionShape](t, s, "search", map[string]any{
		"query": "Charlie", "limit": 5, "min_score": -1,
	})
	if len(all.Results) != len(unfiltered.Results) {
		t.Errorf("min_score -1 dropped results: %v vs %v", ids(all), ids(unfiltered))
	}
}

func TestExactIDObeysTheMinScore(t *testing.T) {
	s := exactIDWorkspace(t)
	// zq-9's raw similarity to its own id is well under 1, so a threshold of
	// 1 drops it, guaranteed hit or not — bv's rule.
	got := call[optionShape](t, s, "search", map[string]any{
		"query": "zq-9", "limit": 2, "min_score": 1,
	})
	for _, id := range ids(got) {
		if id == "zq-9" {
			t.Errorf("an exact id below the threshold was returned: %v", ids(got))
		}
	}
}

func TestMinScoreOutsideItsRangeIsRejected(t *testing.T) {
	s := openFixture(t)
	for _, score := range []string{"1.5", "-1.01", "1e300"} {
		req := []byte(`{"query":"Charlie","min_score":` + score + `}`)
		if _, err := s.Call("search", req); err == nil {
			t.Errorf("min_score %s was accepted", score)
		}
	}
}
