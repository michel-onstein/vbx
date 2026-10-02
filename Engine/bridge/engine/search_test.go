package engine

import (
	"math"
	"strconv"
	"testing"
)

type searchShape struct {
	Query     string `json:"query"`
	Mode      string `json:"mode"`
	Provider  string `json:"provider"`
	Dim       int    `json:"dim"`
	IndexSize int    `json:"index_size"`
	Preset    string `json:"preset"`
	Weights   struct {
		Text     float64 `json:"text"`
		PageRank float64 `json:"pagerank"`
	} `json:"weights"`
	Results []struct {
		IssueID         string             `json:"issue_id"`
		Score           float64            `json:"score"`
		TextScore       float64            `json:"text_score"`
		ComponentScores map[string]float64 `json:"component_scores"`
	} `json:"results"`
}

func TestTextSearchReturnsRankedResults(t *testing.T) {
	s := openFixture(t)
	result := call[searchShape](t, s, "search", map[string]any{"query": "Charlie", "limit": 5})

	if result.Mode != "text" {
		t.Errorf("mode defaulted to %q", result.Mode)
	}
	// The default embedder is the deterministic hash one, which is what keeps
	// vbx's ranking identical to the CLI's.
	if result.Provider != "hash" {
		t.Errorf("provider is %q, want hash", result.Provider)
	}
	if result.IndexSize != 5 {
		t.Errorf("indexed %d beads, want 5", result.IndexSize)
	}
	if len(result.Results) == 0 {
		t.Fatal("no results")
	}
	if len(result.Results) > 5 {
		t.Errorf("returned %d results for a limit of 5", len(result.Results))
	}
	// A term that really appears must score above zero, or the test would
	// pass just as well against an index that matched nothing.
	if result.Results[0].Score <= 0 {
		t.Errorf("the best match for a present term scored %v", result.Results[0].Score)
	}
	// Descending by score.
	for i := 1; i < len(result.Results); i++ {
		if result.Results[i-1].Score < result.Results[i].Score {
			t.Errorf("results are not ordered by score: %+v", result.Results)
		}
	}
}

func TestHybridSearchRescoresWithMetrics(t *testing.T) {
	s := openFixture(t)
	result := call[searchShape](t, s, "search", map[string]any{
		"query": "Charlie", "limit": 5, "mode": "hybrid",
	})

	if result.Mode != "hybrid" {
		t.Fatalf("mode is %q", result.Mode)
	}
	if result.Preset != "default" {
		t.Errorf("preset defaulted to %q", result.Preset)
	}
	if len(result.Results) == 0 {
		t.Fatal("no hybrid results")
	}
	// The breakdown is what makes a hybrid ranking auditable rather than a
	// number to take on trust.
	if len(result.Results[0].ComponentScores) == 0 {
		t.Error("hybrid result carries no component breakdown")
	}

	// Text scores survive the re-scoring. Note this is deliberately not
	// asserted of the *first* result: hybrid can promote a bead on centrality
	// alone, so a zero text score at the top is correct behaviour, not a lost
	// value.
	sawTextScore := false
	for _, entry := range result.Results {
		if entry.TextScore != 0 {
			sawTextScore = true
		}
	}
	if !sawTextScore {
		t.Error("every hybrid result lost its text score")
	}
	for i := 1; i < len(result.Results); i++ {
		if result.Results[i-1].Score < result.Results[i].Score {
			t.Errorf("hybrid results are not ordered: %+v", result.Results)
		}
	}
}

func TestHybridIsDeterministic(t *testing.T) {
	s := openFixture(t)
	first := call[searchShape](t, s, "search", map[string]any{
		"query": "core", "limit": 5, "mode": "hybrid",
	})
	second := call[searchShape](t, s, "search", map[string]any{
		"query": "core", "limit": 5, "mode": "hybrid",
	})

	// Ties break on id, so the same query twice gives the same order.
	if len(first.Results) != len(second.Results) {
		t.Fatalf("result counts differ: %d vs %d", len(first.Results), len(second.Results))
	}
	for i := range first.Results {
		if first.Results[i].IssueID != second.Results[i].IssueID {
			t.Errorf("ordering is unstable at %d: %q vs %q",
				i, first.Results[i].IssueID, second.Results[i].IssueID)
		}
	}
}

// Hybrid recency is measured from SOURCE_DATE_EPOCH, as bv's --robot-search
// measures it, and the instant is echoed as ranking_time (vbx-rgw). The scorer
// used to read the wall clock itself, so two pinned clocks thirty days apart
// gave the same recency — and bv's, pinned, never matched.
func TestHybridRecencyFollowsThePinnedClock(t *testing.T) {
	type pinned struct {
		RankingTime string `json:"ranking_time"`
		Results     []struct {
			IssueID         string             `json:"issue_id"`
			ComponentScores map[string]float64 `json:"component_scores"`
		} `json:"results"`
	}
	const at = int64(1788000000) // 2026-08-29T10:40:00Z, after every fixture bead
	run := func(epoch int64) pinned {
		t.Setenv("SOURCE_DATE_EPOCH", strconv.FormatInt(epoch, 10))
		return call[pinned](t, openFixture(t), "search", map[string]any{
			"query": "core", "limit": 5, "mode": "hybrid",
		})
	}
	now := run(at)
	later := run(at + 30*24*60*60)

	if now.RankingTime != "2026-08-29T10:40:00Z" {
		t.Errorf("ranking_time is %q, want the pinned instant in UTC", now.RankingTime)
	}
	if later.RankingTime != "2026-09-28T10:40:00Z" {
		t.Errorf("ranking_time is %q thirty days on", later.RankingTime)
	}
	if len(now.Results) == 0 || len(now.Results) != len(later.Results) {
		t.Fatalf("result counts %d and %d", len(now.Results), len(later.Results))
	}
	// Recency is exp(-days/30), so thirty more days scales it by exactly 1/e.
	laterByID := make(map[string]float64, len(later.Results))
	for _, entry := range later.Results {
		laterByID[entry.IssueID] = entry.ComponentScores["recency"]
	}
	for _, entry := range now.Results {
		recency, ok := entry.ComponentScores["recency"]
		if !ok || recency <= 0 || recency >= 1 {
			t.Fatalf("%s: recency %v at the pinned clock", entry.IssueID, recency)
		}
		want := recency / math.E
		if got := laterByID[entry.IssueID]; math.Abs(got-want) > 1e-12 {
			t.Errorf("%s: recency %v thirty days on, want %v — the clock is not the pinned one",
				entry.IssueID, got, want)
		}
	}
}

// Text mode ranks nothing by time, and bv omits ranking_time there.
func TestTextSearchCarriesNoRankingTime(t *testing.T) {
	result := call[map[string]any](t, openFixture(t), "search", map[string]any{"query": "core"})
	if _, ok := result["ranking_time"]; ok {
		t.Errorf("text search carries ranking_time %v", result["ranking_time"])
	}
}

func TestSearchPresetsChangeTheWeights(t *testing.T) {
	s := openFixture(t)

	standard := call[searchShape](t, s, "search", map[string]any{
		"query": "core", "mode": "hybrid", "preset": "default",
	})
	textOnly := call[searchShape](t, s, "search", map[string]any{
		"query": "core", "mode": "hybrid", "preset": "text-only",
	})

	if textOnly.Preset != "text-only" {
		t.Errorf("preset came back as %q", textOnly.Preset)
	}
	// text-only puts everything on text relevance and nothing on centrality.
	if textOnly.Weights.PageRank != 0 {
		t.Errorf("text-only gives pagerank %v", textOnly.Weights.PageRank)
	}
	if standard.Weights.PageRank == 0 {
		t.Error("the default preset gives no weight to centrality")
	}
}

func TestExplicitWeightsAreLabelledCustom(t *testing.T) {
	s := openFixture(t)
	result := call[searchShape](t, s, "search", map[string]any{
		"query": "core", "mode": "hybrid",
		"weights": map[string]any{
			"text": 0.5, "pagerank": 0.5, "status": 0, "impact": 0,
			"priority": 0, "recency": 0,
		},
	})
	// Naming a preset the weights no longer match would misreport them.
	if result.Preset != "custom" {
		t.Errorf("explicit weights reported preset %q", result.Preset)
	}
}

func TestSearchRejectsBadInput(t *testing.T) {
	s := openFixture(t)
	cases := map[string][]byte{
		"no request":     nil,
		"empty query":    []byte(`{"query":"  "}`),
		"unknown mode":   []byte(`{"query":"x","mode":"telepathic"}`),
		"unknown preset": []byte(`{"query":"x","mode":"hybrid","preset":"vibes"}`),
	}
	for name, req := range cases {
		if _, err := s.Call("search", req); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestSearchPresetsAreListed(t *testing.T) {
	s := openFixture(t)
	var listed struct {
		Modes   []string `json:"modes"`
		Presets []struct {
			Name    string `json:"name"`
			Weights struct {
				Text float64 `json:"text"`
			} `json:"weights"`
		} `json:"presets"`
	}
	listed = call[struct {
		Modes   []string `json:"modes"`
		Presets []struct {
			Name    string `json:"name"`
			Weights struct {
				Text float64 `json:"text"`
			} `json:"weights"`
		} `json:"presets"`
	}](t, s, "search_presets", nil)

	// bv has exactly two modes; there is no separate "semantic" one, because
	// the vector index is always used and the mode selects the re-ranking.
	if len(listed.Modes) != 2 {
		t.Errorf("modes are %v", listed.Modes)
	}
	if len(listed.Presets) != 5 {
		t.Errorf("listed %d presets, want 5", len(listed.Presets))
	}
	for _, preset := range listed.Presets {
		if preset.Weights.Text == 0 {
			t.Errorf("preset %q gives no weight to text relevance", preset.Name)
		}
	}
}
