package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
)

// Recording triage feedback — bv's --feedback-accept, --feedback-ignore,
// --feedback-reset and --feedback-show (vbx-rt3). Every expected message was
// read from bv 0.25.2 itself, run over a copy of the same fixture at
// readinessClock.

// writableFeedbackFixture copies a feedback fixture's .beads into a temporary
// workspace, because every test here but show writes feedback.json.
func writableFeedbackFixture(t *testing.T, name string) string {
	t.Helper()
	source := filepath.Join(feedbackFixturePath(t, name), ".beads")
	dir := t.TempDir()
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(source)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		raw, err := os.ReadFile(filepath.Join(source, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(beads, entry.Name()), raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// bvFeedbackRunDay is when bv 0.25.2's verdict expectations were read.
var bvFeedbackRunDay = time.Date(2026, 10, 1, 17, 0, 0, 0, time.UTC)

func fixFeedbackScoreClock(t *testing.T, at time.Time) {
	t.Helper()
	previous := feedbackScoreClock
	feedbackScoreClock = func() time.Time { return at }
	t.Cleanup(func() { feedbackScoreClock = previous })
}

type feedbackRecordShape struct {
	Feedback analysis.FeedbackJSON `json:"feedback"`
	Message  string                `json:"message"`
	Path     string                `json:"path"`
	IssueID  string                `json:"issue_id"`
	Action   string                `json:"action"`
	Score    *float64              `json:"score"`
}

func feedbackOnDisk(t *testing.T, workspace string) *analysis.FeedbackData {
	t.Helper()
	fb, err := analysis.LoadFeedback(filepath.Join(workspace, ".beads"))
	if err != nil {
		t.Fatal(err)
	}
	return fb
}

// TestFeedbackShowPrintsBvsBlock: --feedback-show is the block, indented as
// bv indents it, and writes nothing.
func TestFeedbackShowPrintsBvsBlock(t *testing.T) {
	path := feedbackFixturePath(t, "feedback")
	before, err := os.ReadFile(filepath.Join(path, ".beads", analysis.FeedbackFile))
	if err != nil {
		t.Fatal(err)
	}
	s := openFeedback(t, path)
	got := call[feedbackRecordShape](t, s, "triage_feedback", nil)

	// bv 0.25.2. Compared parsed, with the float tolerance, then as text with
	// the effective weights masked: bv normalises them by summing a Go map,
	// whose order is random, so even two runs of bv differ in the last bit.
	want := `{
  "enabled": true,
  "applied": true,
  "min_samples": 3,
  "total_events": 4,
  "accepted_count": 2,
  "ignored_count": 2,
  "avg_accept_score": 0.38,
  "avg_ignore_score": 0.61,
  "weight_adjustments": {
    "Betweenness": 0.5,
    "BlockerRatio": 0.5,
    "PageRank": 0.5,
    "PriorityBoost": 2,
    "Risk": 1,
    "Staleness": 1,
    "TimeToImpact": 1,
    "Urgency": 1
  },
  "effective_weights": {
    "Betweenness": 0.12121212121212123,
    "BlockerRatio": 0.0787878787878788,
    "PageRank": 0.13333333333333333,
    "PriorityBoost": 0.24242424242424246,
    "Risk": 0.12121212121212123,
    "Staleness": 0.060606060606060615,
    "TimeToImpact": 0.12121212121212123,
    "Urgency": 0.12121212121212123
  },
  "updated_at": "2026-08-20T09:30:00Z"
}`
	var gotBlock, wantBlock analysis.FeedbackJSON
	if err := json.Unmarshal([]byte(got.Message), &gotBlock); err != nil {
		t.Fatalf("message is not JSON: %v\n%s", err, got.Message)
	}
	if err := json.Unmarshal([]byte(want), &wantBlock); err != nil {
		t.Fatal(err)
	}
	for name, weight := range wantBlock.EffectiveWeights {
		if !near(gotBlock.EffectiveWeights[name], weight) {
			t.Errorf("effective %s = %v, want bv's %v", name, gotBlock.EffectiveWeights[name], weight)
		}
	}
	if mask := maskEffectiveWeights(got.Message); mask != maskEffectiveWeights(want) {
		t.Errorf("message =\n%s\nwant bv's\n%s", got.Message, want)
	}
	if got.Feedback.TotalEvents != 4 || got.Score != nil || got.IssueID != "" {
		t.Errorf("show result = %+v", got)
	}
	after, err := os.ReadFile(filepath.Join(path, ".beads", analysis.FeedbackFile))
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Error("--feedback-show rewrote feedback.json")
	}
}

// maskEffectiveWeights blanks the values inside show's effective_weights
// block, keeping its keys, its order and everything around it.
func maskEffectiveWeights(text string) string {
	var out []string
	inside := false
	for _, line := range strings.Split(text, "\n") {
		switch {
		case strings.Contains(line, `"effective_weights": {`):
			inside = true
		case inside && strings.HasPrefix(strings.TrimSpace(line), "}"):
			inside = false
		case inside:
			line = line[:strings.Index(line, ":")+1] + " #"
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

// TestFeedbackShowWithoutFileWritesNothing: no file is the defaults, not an
// error, and showing them does not create one.
func TestFeedbackShowWithoutFileWritesNothing(t *testing.T) {
	workspace := writableFeedbackFixture(t, "feedback")
	if err := os.Remove(filepath.Join(workspace, ".beads", analysis.FeedbackFile)); err != nil {
		t.Fatal(err)
	}
	s := openFeedback(t, workspace)
	got := call[feedbackRecordShape](t, s, "triage_feedback", nil)
	if got.Feedback.Enabled || got.Feedback.TotalEvents != 0 ||
		got.Feedback.WeightAdjustments["PageRank"] != 1 {
		t.Errorf("defaults = %+v", got.Feedback)
	}
	if _, err := os.Stat(filepath.Join(workspace, ".beads", analysis.FeedbackFile)); !os.IsNotExist(err) {
		t.Errorf("show created feedback.json (stat err %v)", err)
	}
}

// TestFeedbackAcceptAndIgnoreRecordBvsVerdicts: the score is the bead's
// default-weight impact score, the summary is bv's, and both verdicts reach
// the file through bv's own RecordFeedback — including a closed bead, which
// bv records at zero.
//
// bv scores a verdict at the wall clock, ignoring SOURCE_DATE_EPOCH, so the
// expectations were read from bv 0.25.2 run on bvFeedbackRunDay and the score
// clock is fixed there — while openFeedback pins SOURCE_DATE_EPOCH to
// readinessClock, a month earlier, which must make no difference.
func TestFeedbackAcceptAndIgnoreRecordBvsVerdicts(t *testing.T) {
	fixFeedbackScoreClock(t, bvFeedbackRunDay)
	workspace := writableFeedbackFixture(t, "feedback")
	s := openFeedback(t, workspace)

	accepted := call[feedbackRecordShape](t, s, "triage_feedback_record",
		map[string]string{"id": "fb-5", "action": "accept"})
	// bv 0.25.2.
	if want := "Recorded accept feedback for fb-5 (score: 0.376)\n" +
		"Feedback: 3 accepted (avg score 0.38), 2 ignored (avg score 0.61), 5 total events"; accepted.Message != want {
		t.Errorf("accept message =\n%s\nwant bv's\n%s", accepted.Message, want)
	}
	if accepted.IssueID != "fb-5" || accepted.Action != "accept" || accepted.Score == nil ||
		fmt.Sprintf("%.3f", *accepted.Score) != "0.376" {
		t.Errorf("accept result = %+v", accepted)
	}

	ignored := call[feedbackRecordShape](t, s, "triage_feedback_record",
		map[string]string{"id": "fb-8", "action": "ignore"})
	// bv 0.25.2: fb-8 is closed, so it has no impact score.
	if want := "Recorded ignore feedback for fb-8 (score: 0.000)\n" +
		"Feedback: 3 accepted (avg score 0.38), 3 ignored (avg score 0.41), 6 total events"; ignored.Message != want {
		t.Errorf("ignore message =\n%s\nwant bv's\n%s", ignored.Message, want)
	}

	disk := feedbackOnDisk(t, workspace)
	if len(disk.Events) != 6 {
		t.Fatalf("feedback.json holds %d events, want 6", len(disk.Events))
	}
	last := disk.Events[4:]
	if last[0].IssueID != "fb-5" || last[0].Action != "accept" ||
		last[1].IssueID != "fb-8" || last[1].Action != "ignore" || last[1].Score != 0 {
		t.Errorf("recorded events = %+v", last)
	}
	if ignored.Path != filepath.Join(workspace, ".beads", analysis.FeedbackFile) {
		t.Errorf("path = %s", ignored.Path)
	}
}

// TestFeedbackRecordRejectsWhatBvRejects: an unknown id and a tombstone are
// both bv's "Issue not found", an action other than accept or ignore is
// refused, and none of them touches the file.
func TestFeedbackRecordRejectsWhatBvRejects(t *testing.T) {
	setClock(t, readinessClock)
	workspace := t.TempDir()
	beads := filepath.Join(workspace, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(readinessFixturePath(t), ".beads", "issues.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(beads, "issues.jsonl"), raw, 0o644); err != nil {
		t.Fatal(err)
	}
	s := openFeedback(t, workspace)

	for _, tc := range []struct{ id, action, want string }{
		{"no-such-bead", "accept", "Issue not found: no-such-bead"},
		{"rdy-10", "accept", "Issue not found: rdy-10"}, // a tombstone, as bv 0.25.2 reports it
		{"rdy-11", "promote", "invalid action: promote"},
		{"", "accept", `requires an "id"`},
	} {
		req, _ := json.Marshal(map[string]string{"id": tc.id, "action": tc.action})
		_, err := s.Call("triage_feedback_record", req)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s %s: err = %v, want %q", tc.action, tc.id, err, tc.want)
		}
	}
	if _, err := os.Stat(filepath.Join(beads, analysis.FeedbackFile)); !os.IsNotExist(err) {
		t.Errorf("a refused verdict wrote feedback.json (stat err %v)", err)
	}
}

// TestFeedbackRecordRefusesAnUnreadableFile: the read path treats a corrupt
// file as no feedback, but a write must not replace it with one verdict.
func TestFeedbackRecordRefusesAnUnreadableFile(t *testing.T) {
	workspace := writableFeedbackFixture(t, "feedback")
	path := filepath.Join(workspace, ".beads", analysis.FeedbackFile)
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := openFeedback(t, workspace)
	req, _ := json.Marshal(map[string]string{"id": "fb-5", "action": "accept"})
	if _, err := s.Call("triage_feedback_record", req); err == nil ||
		!strings.Contains(err.Error(), "Error loading feedback") {
		t.Errorf("err = %v, want bv's load error", err)
	}
	if raw, _ := os.ReadFile(path); string(raw) != "{not json" {
		t.Errorf("the unreadable file was overwritten: %s", raw)
	}
}

// TestFeedbackResetClearsTheFile: reset keeps the file and empties it.
func TestFeedbackResetClearsTheFile(t *testing.T) {
	workspace := writableFeedbackFixture(t, "feedback")
	s := openFeedback(t, workspace)
	got := call[feedbackRecordShape](t, s, "triage_feedback_reset", nil)
	if got.Message != "Feedback data reset to defaults." {
		t.Errorf("message = %q, want bv's", got.Message)
	}
	if got.Feedback.Enabled || got.Feedback.TotalEvents != 0 {
		t.Errorf("after reset = %+v", got.Feedback)
	}
	disk := feedbackOnDisk(t, workspace)
	if len(disk.Events) != 0 || disk.GetAdjustedWeights()["PriorityBoost"] != 1 {
		t.Errorf("feedback.json after reset = %+v", disk)
	}
}

// TestFeedbackWriteReachesTriageThroughReload: a verdict changes no bead, so
// only the feedback fingerprint can tell the reload anything changed. The
// write leaves the session's copy alone — the app's file watch triggers the
// reload — and that reload must report `changed` and apply the new weights.
// Two verdicts plus a third crosses MinFeedbackSamples, which reorders
// triage from the hub first to fb-5 first.
func TestFeedbackWriteReachesTriageThroughReload(t *testing.T) {
	workspace := writableFeedbackFixture(t, "feedback-few")
	s := openFeedback(t, workspace)

	before := call[feedbackTriageShape](t, s, "triage", nil)
	if before.Feedback == nil || before.Feedback.Applied || before.order()[0] != "fb-1" {
		t.Fatalf("precondition: triage = %v, feedback %+v", before.order(), before.Feedback)
	}

	call[feedbackRecordShape](t, s, "triage_feedback_record",
		map[string]string{"id": "fb-5", "action": "accept"})

	stale := call[feedbackTriageShape](t, s, "triage", nil)
	if stale.Feedback.TotalEvents != 2 {
		t.Errorf("the write refreshed the session itself (%d events); the reload would then"+
			" report nothing changed", stale.Feedback.TotalEvents)
	}

	reload := call[struct {
		Changed bool `json:"changed"`
	}](t, s, "reload", nil)
	if !reload.Changed {
		t.Fatal("reload after a feedback write reported nothing changed")
	}
	after := call[feedbackTriageShape](t, s, "triage", nil)
	if after.Feedback == nil || !after.Feedback.Applied || after.Feedback.TotalEvents != 3 {
		t.Fatalf("feedback after reload = %+v", after.Feedback)
	}
	if after.order()[0] != "fb-5" || slices.Equal(after.order(), before.order()) {
		t.Errorf("order after reload = %v, want fb-5 first", after.order())
	}
}
