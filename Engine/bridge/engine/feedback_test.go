package engine

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
)

// Fixtures/feedback and Fixtures/feedback-few hold the same eight beads: a P3
// hub (fb-1) blocking two, a P0 standalone bead labelled urgent (fb-5), a P1
// bead labelled needs-design (fb-6), and controls. The first has four
// accept/ignore verdicts whose adjustments boost PriorityBoost and damp the
// graph factors; the second has two, below analysis.MinFeedbackSamples.
//
// Every expectation marked "bv 0.25.2" was read from bv 0.25.2 itself over the
// fixture at readinessClock (parity-check.py's PINNED_CLOCK) — vbx-5ba.

func feedbackFixturePath(t *testing.T, name string) string {
	t.Helper()
	path, err := filepath.Abs(filepath.Join("..", "..", "..", "Fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(path, ".beads", "issues.jsonl")); err != nil {
		t.Fatalf("%s fixture missing: %v", name, err)
	}
	return path
}

func openFeedback(t *testing.T, path string) *Session {
	t.Helper()
	setClock(t, readinessClock)
	s, err := Open(OpenConfig{Path: path})
	if err != nil {
		t.Fatalf("Open(%s): %v", path, err)
	}
	t.Cleanup(s.Close)
	return s
}

type feedbackTriageShape struct {
	Recommendations []struct {
		ID        string  `json:"id"`
		Score     float64 `json:"score"`
		Claimable bool    `json:"claimable"`
	} `json:"recommendations"`
	QuickRef struct {
		TopPicks []struct {
			ID string `json:"id"`
		} `json:"top_picks"`
	} `json:"quick_ref"`
	Feedback *struct {
		Enabled          bool               `json:"enabled"`
		Applied          bool               `json:"applied"`
		MinSamples       int                `json:"min_samples"`
		TotalEvents      int                `json:"total_events"`
		AcceptedCount    int                `json:"accepted_count"`
		IgnoredCount     int                `json:"ignored_count"`
		EffectiveWeights map[string]float64 `json:"effective_weights"`
	} `json:"feedback"`
}

func (t feedbackTriageShape) order() []string {
	ids := make([]string, len(t.Recommendations))
	for i, rec := range t.Recommendations {
		ids[i] = rec.ID
	}
	return ids
}

func (t feedbackTriageShape) picks() []string {
	ids := make([]string, len(t.QuickRef.TopPicks))
	for i, pick := range t.QuickRef.TopPicks {
		ids[i] = pick.ID
	}
	return ids
}

func near(a, b float64) bool { return math.Abs(a-b) < 1e-4 }

// TestFeedbackWeightsApplyFromThreeSamples: four verdicts move the scores and
// put fb-5 above the hub, exactly as bv ranks them, and triage reports the
// block beside the result.
func TestFeedbackWeightsApplyFromThreeSamples(t *testing.T) {
	s := openFeedback(t, feedbackFixturePath(t, "feedback"))
	got := call[feedbackTriageShape](t, s, "triage", nil)

	// bv 0.25.2.
	want := []string{"fb-5", "fb-1", "fb-6", "fb-7", "fb-4", "fb-2", "fb-3"}
	if !slices.Equal(got.order(), want) {
		t.Fatalf("order = %v, want bv's %v", got.order(), want)
	}
	if !near(got.Recommendations[0].Score, 0.4421) || !near(got.Recommendations[1].Score, 0.4344) {
		t.Errorf("scores = %v, %v; want bv's 0.4421, 0.4344",
			got.Recommendations[0].Score, got.Recommendations[1].Score)
	}

	fb := got.Feedback
	if fb == nil {
		t.Fatal("triage has no feedback block")
	}
	if !fb.Enabled || !fb.Applied || fb.MinSamples != analysis.MinFeedbackSamples ||
		fb.TotalEvents != 4 || fb.AcceptedCount != 2 || fb.IgnoredCount != 2 {
		t.Errorf("feedback block = %+v", *fb)
	}
	if w := fb.EffectiveWeights["PriorityBoost"]; !near(w, 0.2424) {
		t.Errorf("effective PriorityBoost = %v, want bv's 0.2424", w)
	}
}

// TestFeedbackBelowThreeSamplesIsReportedNotApplied: two verdicts leave the
// ranking at the defaults — the hub first — but the block is still reported,
// saying it was not applied.
func TestFeedbackBelowThreeSamplesIsReportedNotApplied(t *testing.T) {
	s := openFeedback(t, feedbackFixturePath(t, "feedback-few"))
	got := call[feedbackTriageShape](t, s, "triage", nil)

	// bv 0.25.2: the default-weight ranking.
	want := []string{"fb-1", "fb-5", "fb-6", "fb-7", "fb-4", "fb-2", "fb-3"}
	if !slices.Equal(got.order(), want) {
		t.Fatalf("order = %v, want bv's %v", got.order(), want)
	}
	if !near(got.Recommendations[0].Score, 0.4964) {
		t.Errorf("fb-1 score = %v, want bv's default-weight 0.4964", got.Recommendations[0].Score)
	}
	if got.Feedback == nil {
		t.Fatal("two verdicts are still reported")
	}
	if !got.Feedback.Enabled || got.Feedback.Applied || got.Feedback.TotalEvents != 2 {
		t.Errorf("feedback block = %+v, want enabled and not applied", *got.Feedback)
	}
}

// TestNoFeedbackFileMeansNoBlock: absent, never an empty block reporting zero
// verdicts.
func TestNoFeedbackFileMeansNoBlock(t *testing.T) {
	s := openFeedback(t, readinessFixturePath(t))
	out, err := s.Call("triage", nil)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(out, &raw); err != nil {
		t.Fatal(err)
	}
	if _, present := raw["feedback"]; present {
		t.Errorf("triage carries a feedback block with no feedback.json: %s", raw["feedback"])
	}
	if _, present := raw["recommendations"]; !present {
		t.Error("the triage result is no longer at the payload's top level")
	}
}

// TestNextAndPriorityUseFeedbackWeights: bv's --robot-next and
// --robot-priority score with the same weights triage does.
func TestNextAndPriorityUseFeedbackWeights(t *testing.T) {
	s := openFeedback(t, feedbackFixturePath(t, "feedback"))

	next := call[struct {
		Diagnostic *struct {
			ID    string  `json:"id"`
			Score float64 `json:"score"`
		} `json:"diagnostic_top_pick"`
	}](t, s, "next", nil)
	// bv 0.25.2.
	if next.Diagnostic == nil || next.Diagnostic.ID != "fb-5" || !near(next.Diagnostic.Score, 0.4421) {
		t.Errorf("next's pick = %+v, want bv's fb-5 at 0.4421", next.Diagnostic)
	}

	type priorityShape struct {
		Recommendations []struct {
			IssueID     string  `json:"issue_id"`
			ImpactScore float64 `json:"impact_score"`
		} `json:"recommendations"`
	}
	priority := call[priorityShape](t, s, "priority", nil)
	// bv 0.25.2: fb-5 0.5286, fb-1 0.4574, fb-6 0.4074.
	if len(priority.Recommendations) != 3 || priority.Recommendations[0].IssueID != "fb-5" ||
		!near(priority.Recommendations[0].ImpactScore, 0.5286) {
		t.Errorf("priority = %+v, want bv's fb-5 first at 0.5286", priority.Recommendations)
	}

	// The weights held for that one computation: the session's analyzer is
	// shared with every other call, and must score with the defaults again.
	s.mu.RLock()
	an := s.analyzer
	s.mu.RUnlock()
	if an.Weights() != analysis.DefaultWeights() {
		t.Errorf("priority left the shared analyzer on %+v", an.Weights())
	}
}

// TestNotReadyLabelsLeaveTheTopPicks: the label-class keeps fb-6 out of the
// claimable picks without changing the ranking, as bv's
// --robot-not-ready-labels does.
func TestNotReadyLabelsLeaveTheTopPicks(t *testing.T) {
	s := openFeedback(t, feedbackFixturePath(t, "feedback"))

	plain := call[feedbackTriageShape](t, s, "triage", nil)
	gated := call[feedbackTriageShape](t, s, "triage",
		map[string]any{"not_ready_labels": " Needs-Design , ,"})

	// bv 0.25.2, with and without --robot-not-ready-labels needs-design.
	// Matching is case-insensitive, and the list is trimmed.
	if want := []string{"fb-5", "fb-1", "fb-6"}; !slices.Equal(plain.picks(), want) {
		t.Errorf("picks = %v, want %v", plain.picks(), want)
	}
	if want := []string{"fb-5", "fb-1", "fb-7"}; !slices.Equal(gated.picks(), want) {
		t.Errorf("gated picks = %v, want %v", gated.picks(), want)
	}
	if !slices.Equal(plain.order(), gated.order()) {
		t.Errorf("the gate reordered the ranking: %v vs %v", plain.order(), gated.order())
	}
	for _, rec := range gated.Recommendations {
		if rec.ID == "fb-6" && rec.Claimable {
			t.Error("fb-6 is still claimable under its not-ready label")
		}
	}
}

func TestNotReadyLabelsParse(t *testing.T) {
	for raw, want := range map[string][]string{
		"":                  nil,
		" , ,":              nil,
		"needs-design":      {"needs-design"},
		" a , B ,, c ":      {"a", "B", "c"},
		"needs-design,spec": {"needs-design", "spec"},
	} {
		if got := notReadyLabels(raw); !slices.Equal(got, want) {
			t.Errorf("notReadyLabels(%q) = %v, want %v", raw, got, want)
		}
	}
}

// TestFeedbackEditAloneReloads: feedback.json is not bead data, so the bead
// hash cannot see it change. The reload must still report a change — the
// app re-reads triage only when it does — and triage must follow the file.
func TestFeedbackEditAloneReloads(t *testing.T) {
	src := feedbackFixturePath(t, "feedback")
	dir := t.TempDir()
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	copyFile := func(from, to string) {
		t.Helper()
		data, err := os.ReadFile(from)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(to, data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	copyFile(filepath.Join(src, ".beads", "issues.jsonl"), filepath.Join(beads, "issues.jsonl"))
	feedbackPath := filepath.Join(beads, analysis.FeedbackFile)

	s := openFeedback(t, dir)
	reload := func() bool {
		t.Helper()
		return call[struct {
			Changed bool `json:"changed"`
		}](t, s, "reload", nil).Changed
	}
	first := func() (string, bool) {
		t.Helper()
		got := call[feedbackTriageShape](t, s, "triage", nil)
		return got.order()[0], got.Feedback != nil
	}

	if top, block := first(); top != "fb-1" || block {
		t.Fatalf("without feedback: top %s, block %v; want fb-1 and none", top, block)
	}

	copyFile(filepath.Join(src, ".beads", analysis.FeedbackFile), feedbackPath)
	if !reload() {
		t.Fatal("adding feedback.json did not reload")
	}
	if top, block := first(); top != "fb-5" || !block {
		t.Errorf("with feedback: top %s, block %v; want fb-5 and a block", top, block)
	}
	if reload() {
		t.Error("an untouched feedback.json reported a change")
	}

	// bv swallows a file it cannot parse and scores with the defaults.
	if err := os.WriteFile(feedbackPath, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !reload() {
		t.Fatal("corrupting feedback.json did not reload")
	}
	if top, block := first(); top != "fb-1" || block {
		t.Errorf("unparseable feedback: top %s, block %v; want fb-1 and none", top, block)
	}

	if err := os.Remove(feedbackPath); err != nil {
		t.Fatal(err)
	}
	if !reload() {
		t.Error("removing feedback.json did not reload")
	}
}
