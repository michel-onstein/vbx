package engine

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
)

// Which feedback.json a robot command reads (vbx-15s). bv 0.25.2's triage,
// next and priority all read it through loader.GetBeadsDir(""), the working
// directory's `.beads`, whichever graph they answer over. From a folder below
// a workspace root that is the folder's own `.beads` — absent — so bv reports
// no feedback block and scores with the default weights, with --workspace or
// without. vbx-cli opens with FeedbackFromPath to match; the app does not,
// and keeps the root's file, which it both shows and writes.

// feedbackBelowRootLayout is the parity harness's discovery layout: a
// discovered workspace whose root holds a `.beads` of its own, with
// Fixtures/feedback's four verdicts in it — enough to apply the weights —
// and a plain `notes/` folder. The members carry a blocking chain so that
// the feedback weights move the scores. Returns the root and `notes/`.
func feedbackBelowRootLayout(t *testing.T, withFeedback bool) (string, string) {
	t.Helper()
	bead := func(id, title string, priority string, deps string) string {
		return `{"id":"` + id + `","title":"` + title + `","status":"open","issue_type":"task","priority":` +
			priority + `,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"` + deps + "}\n"
	}
	blocks := func(id, on string) string {
		return `,"dependencies":[{"issue_id":"` + id + `","depends_on_id":"` + on +
			`","type":"blocks","created_at":"2026-01-01T00:00:00Z"}]`
	}
	root := writeWorkspace(t, feedbackWorkspaceConfig, map[string]string{
		"api": bead("1", "Serve", "3", "") +
			bead("2", "Route", "2", blocks("2", "1")) +
			bead("3", "Cache", "2", blocks("3", "1")) +
			bead("4", "Urgent", "0", ""),
		"web": bead("1", "Form", "1", ""),
	})
	src := filepath.Join(feedbackFixturePath(t, "feedback"), ".beads")
	rootBeads := filepath.Join(root, ".beads")
	if err := os.MkdirAll(rootBeads, 0o755); err != nil {
		t.Fatal(err)
	}
	files := []string{"issues.jsonl"}
	if withFeedback {
		files = append(files, analysis.FeedbackFile)
	}
	for _, name := range files {
		raw, err := os.ReadFile(filepath.Join(src, name))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(rootBeads, name), raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	notes := filepath.Join(root, "notes")
	if err := os.Mkdir(notes, 0o755); err != nil {
		t.Fatal(err)
	}
	return root, notes
}

func openFeedbackConfig(t *testing.T, cfg OpenConfig) *Session {
	t.Helper()
	setClock(t, readinessClock)
	s, err := Open(cfg)
	if err != nil {
		t.Fatalf("Open(%+v): %v", cfg, err)
	}
	t.Cleanup(s.Close)
	return s
}

// scoringShape is what the three scoring surfaces report that feedback
// weights move: triage's order, scores and block, next's pick and priority's
// impact scores.
type scoringShape struct {
	triage   feedbackTriageShape
	next     float64
	priority []float64
}

func scoring(t *testing.T, s *Session) scoringShape {
	t.Helper()
	next := call[struct {
		Diagnostic *struct {
			Score float64 `json:"score"`
		} `json:"diagnostic_top_pick"`
	}](t, s, "next", nil)
	if next.Diagnostic == nil {
		t.Fatal("next has no diagnostic top pick")
	}
	priority := call[struct {
		Recommendations []struct {
			ImpactScore float64 `json:"impact_score"`
		} `json:"recommendations"`
	}](t, s, "priority", nil)
	got := scoringShape{triage: call[feedbackTriageShape](t, s, "triage", nil), next: next.Diagnostic.Score}
	for _, rec := range priority.Recommendations {
		got.priority = append(got.priority, rec.ImpactScore)
	}
	return got
}

func sameScoring(a, b scoringShape) bool {
	if len(a.triage.Recommendations) != len(b.triage.Recommendations) || len(a.priority) != len(b.priority) {
		return false
	}
	for i := range a.triage.Recommendations {
		if a.triage.Recommendations[i].ID != b.triage.Recommendations[i].ID ||
			!near(a.triage.Recommendations[i].Score, b.triage.Recommendations[i].Score) {
			return false
		}
	}
	for i := range a.priority {
		if !near(a.priority[i], b.priority[i]) {
			return false
		}
	}
	return near(a.next, b.next)
}

// TestPathFeedbackBelowAWorkspaceRoot is the bead's reproduction: from
// `notes/`, with --workspace and without, triage reports no feedback block
// and triage, next and priority score exactly as with no feedback.json at
// all. vbx-cli used to report and apply the root's.
func TestPathFeedbackBelowAWorkspaceRoot(t *testing.T) {
	root, notes := feedbackBelowRootLayout(t, true)
	_, controlNotes := feedbackBelowRootLayout(t, false)
	control := scoring(t, openFeedbackConfig(t, OpenConfig{Path: controlNotes, FeedbackFromPath: true}))

	// The premise: the root's verdicts, applied, do move these scores.
	appRule := openFeedbackConfig(t, OpenConfig{Path: notes})
	if appRule.kind != "workspace" {
		t.Fatalf("notes/ opens as %q, want the discovered workspace", appRule.kind)
	}
	if sameScoring(scoring(t, appRule), control) {
		t.Fatal("the root's feedback does not move the scores; the test proves nothing")
	}

	config := filepath.Join(root, ".bv", "workspace.yaml")
	for name, cfg := range map[string]OpenConfig{
		"discovered":  {Path: notes, FeedbackFromPath: true},
		"--workspace": {Path: notes, Workspace: config, FeedbackFromPath: true},
	} {
		s := openFeedbackConfig(t, cfg)
		if s.kind != "workspace" {
			t.Errorf("%s: opens as %q, want the workspace", name, s.kind)
		}
		got := scoring(t, s)
		if got.triage.Feedback != nil {
			t.Errorf("%s: triage reports the root's feedback block (%d events); bv reports none",
				name, got.triage.Feedback.TotalEvents)
		}
		if !sameScoring(got, control) {
			t.Errorf("%s: scores with the root's feedback weights, want bv's defaults", name)
		}
	}
}

// TestPathFeedbackAtAWorkspaceRoot: at the root the working directory's
// `.beads` is the root's, so its block is reported and its weights applied —
// whether the root's own repository or, by --workspace, the members are
// scored.
func TestPathFeedbackAtAWorkspaceRoot(t *testing.T) {
	root, _ := feedbackBelowRootLayout(t, true)
	for name, cfg := range map[string]OpenConfig{
		"discovered":  {Path: root, FeedbackFromPath: true},
		"--workspace": {Path: root, Workspace: filepath.Join(root, ".bv", "workspace.yaml"), FeedbackFromPath: true},
	} {
		s := openFeedbackConfig(t, cfg)
		got := call[feedbackTriageShape](t, s, "triage", nil)
		if got.Feedback == nil || got.Feedback.TotalEvents != 4 || !got.Feedback.Applied {
			t.Errorf("%s: feedback block = %+v, want the root's four verdicts, applied", name, got.Feedback)
		}
		if s.feedbackWeights() == nil {
			t.Errorf("%s: the root's weights are not applied", name)
		}
	}
}

// TestPathFeedbackInARepository: for a single repository the working
// directory's `.beads` is the data's, so nothing changes.
func TestPathFeedbackInARepository(t *testing.T) {
	path := feedbackFixturePath(t, "feedback")
	ordinary := call[feedbackTriageShape](t, openFeedback(t, path), "triage", nil)
	got := call[feedbackTriageShape](t,
		openFeedbackConfig(t, OpenConfig{Path: path, FeedbackFromPath: true}), "triage", nil)
	if got.Feedback == nil || got.Feedback.TotalEvents != ordinary.Feedback.TotalEvents {
		t.Errorf("feedback block = %+v, want the repository's own", got.Feedback)
	}
	if len(got.order()) == 0 || got.order()[0] != ordinary.order()[0] {
		t.Errorf("order = %v, want %v", got.order(), ordinary.order())
	}
}

// TestAppFeedbackBelowAWorkspaceRootStaysTheRoots: the app opens without
// FeedbackFromPath, and must show the file it writes. A verdict recorded in a
// workspace session lands in the root's `.beads` — never the folder's — and
// the reload that follows shows it.
func TestAppFeedbackBelowAWorkspaceRootStaysTheRoots(t *testing.T) {
	fixFeedbackScoreClock(t, bvFeedbackRunDay)
	root, notes := feedbackBelowRootLayout(t, true)
	s := openFeedbackConfig(t, OpenConfig{Path: notes})

	before := call[feedbackTriageShape](t, s, "triage", nil)
	if before.Feedback == nil || before.Feedback.TotalEvents != 4 {
		t.Fatalf("the app's triage block = %+v, want the root's four verdicts", before.Feedback)
	}
	recorded := call[feedbackRecordShape](t, s, "triage_feedback_record",
		map[string]string{"id": "api-4", "action": "accept"})
	if want := filepath.Join(root, ".beads", analysis.FeedbackFile); recorded.Path != want {
		t.Errorf("verdict written to %s, want %s", recorded.Path, want)
	}
	if _, err := os.Stat(filepath.Join(notes, ".beads")); !os.IsNotExist(err) {
		t.Errorf("the app created notes/.beads (stat err %v)", err)
	}
	if !call[struct {
		Changed bool `json:"changed"`
	}](t, s, "reload", nil).Changed {
		t.Fatal("recording a verdict did not reload")
	}
	after := call[feedbackTriageShape](t, s, "triage", nil)
	if after.Feedback == nil || after.Feedback.TotalEvents != 5 {
		t.Errorf("after the verdict the block = %+v, want the five the app wrote", after.Feedback)
	}
}
