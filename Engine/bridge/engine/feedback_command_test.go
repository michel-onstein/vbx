package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
)

// bv's feedback commands answer before workspace discovery (vbx-v1t). Every
// expected message here was read from bv 0.25.2 run over the same layout: a
// copy of Fixtures/dropped-workspace outside any checkout, and the parity
// harness's discovery workspace, whose root has a `.beads` of its own.

const feedbackWorkspaceConfig = `repos:
  - {name: api, path: api, prefix: "api-"}
  - {name: web, path: web, prefix: "web-"}
`

// discoveredFeedbackWorkspace is a workspace whose root holds no `.beads`,
// so every robot command there answers over the members.
func discoveredFeedbackWorkspace(t *testing.T) string {
	t.Helper()
	return writeWorkspace(t, feedbackWorkspaceConfig, map[string]string{
		"api": `{"id":"1","title":"Serve","status":"open","issue_type":"task","priority":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}` + "\n",
		"web": `{"id":"1","title":"Form","status":"open","issue_type":"task","priority":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}` + "\n",
	})
}

func openFeedbackCommand(t *testing.T, cfg OpenConfig) *Session {
	t.Helper()
	setClock(t, readinessClock)
	cfg.FeedbackCommand = true
	s, err := Open(cfg)
	if err != nil {
		t.Fatalf("Open(%+v): %v", cfg, err)
	}
	t.Cleanup(s.Close)
	return s
}

func feedbackCallError(t *testing.T, s *Session, method string, req any) string {
	t.Helper()
	var raw []byte
	if req != nil {
		raw, _ = json.Marshal(req)
	}
	_, err := s.Call(method, raw)
	if err == nil {
		t.Fatalf("%s %v: succeeded, want bv's error", method, req)
	}
	return err.Error()
}

// TestFeedbackCommandInADiscoveredWorkspace is the bead's reproduction: at a
// workspace root with no `.beads`, bv reads the root's own `.beads` and
// never the workspace. Show is the defaults, reset cannot write, and a
// verdict — even on a member's bead — fails to load, with no discovery
// notice. vbx used to answer the verdict over the whole workspace.
func TestFeedbackCommandInADiscoveredWorkspace(t *testing.T) {
	root := discoveredFeedbackWorkspace(t)

	// The premise: an ordinary open of the same folder is the workspace.
	if ordinary := openFeedback(t, root); ordinary.kind != "workspace" {
		t.Fatalf("an ordinary open is %q, want the discovered workspace", ordinary.kind)
	}

	s := openFeedbackCommand(t, OpenConfig{Path: root})
	info := call[map[string]any](t, s, "info", nil)
	if stderr, _ := info["load_stderr"].([]any); len(stderr) != 0 {
		t.Errorf("load_stderr = %v, want nothing: bv prints no discovery notice here", stderr)
	}

	shown := call[feedbackRecordShape](t, s, "triage_feedback", nil)
	if shown.Feedback.TotalEvents != 0 || shown.Path != filepath.Join(root, ".beads", "feedback.json") {
		t.Errorf("show = %d events from %s, want the defaults from the root's .beads",
			shown.Feedback.TotalEvents, shown.Path)
	}

	beads := filepath.Join(root, ".beads")
	if got, want := feedbackCallError(t, s, "triage_feedback_reset", nil),
		"Error saving feedback: failed to write feedback file: open "+
			filepath.Join(beads, "feedback.json")+": no such file or directory"; got != want {
		t.Errorf("reset:\n got %q\nwant %q", got, want)
	}

	loadErr := "Error loading issues: failed to read beads directory: open " + beads +
		": no such file or directory"
	for _, id := range []string{"no-such-bead", "api-1", "web-1"} {
		got := feedbackCallError(t, s, "triage_feedback_record",
			map[string]string{"id": id, "action": "accept"})
		if got != loadErr {
			t.Errorf("accept %s:\n got %q\nwant %q", id, got, loadErr)
		}
	}
	if _, err := os.Stat(beads); !os.IsNotExist(err) {
		t.Errorf("the root's .beads was created (stat err %v)", err)
	}
}

// TestFeedbackCommandIgnoresWorkspace: bv reads --workspace only after it has
// answered the feedback flags, so naming the configuration changes nothing.
func TestFeedbackCommandIgnoresWorkspace(t *testing.T) {
	root := discoveredFeedbackWorkspace(t)
	s := openFeedbackCommand(t, OpenConfig{
		Path: root, Workspace: filepath.Join(root, ".bv", "workspace.yaml"),
	})
	got := feedbackCallError(t, s, "triage_feedback_record",
		map[string]string{"id": "web-1", "action": "ignore"})
	if !strings.HasPrefix(got, "Error loading issues: failed to read beads directory") {
		t.Errorf("ignore web-1 with --workspace: %q, want bv's load failure", got)
	}
}

// TestFeedbackCommandBelowAWorkspaceRoot: from a folder below a root that
// has a `.beads` of its own, the folder's `.beads` is the one bv reads — not
// the root's, where vbx used to read, show and write.
func TestFeedbackCommandBelowAWorkspaceRoot(t *testing.T) {
	root := discoveredFeedbackWorkspace(t)
	rootBeads := filepath.Join(root, ".beads")
	if err := os.MkdirAll(rootBeads, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(rootBeads, "issues.jsonl"),
		[]byte(`{"id":"vbx-2","title":"Root","status":"open","issue_type":"task","priority":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}`+"\n"),
		0o644); err != nil {
		t.Fatal(err)
	}
	notes := filepath.Join(root, "notes")
	if err := os.Mkdir(notes, 0o755); err != nil {
		t.Fatal(err)
	}

	// A verdict at the root is the root's, as a single repository.
	fixFeedbackScoreClock(t, bvFeedbackRunDay)
	atRoot := openFeedbackCommand(t, OpenConfig{Path: root})
	call[feedbackRecordShape](t, atRoot, "triage_feedback_record",
		map[string]string{"id": "vbx-2", "action": "accept"})
	before, err := os.ReadFile(filepath.Join(rootBeads, analysis.FeedbackFile))
	if err != nil {
		t.Fatalf("the root's verdict was not written: %v", err)
	}

	below := openFeedbackCommand(t, OpenConfig{Path: notes})
	shown := call[feedbackRecordShape](t, below, "triage_feedback", nil)
	if shown.Feedback.TotalEvents != 0 {
		t.Errorf("show below the root reports %d events, want the defaults: bv does not"+
			" read the root's file", shown.Feedback.TotalEvents)
	}
	if got := feedbackCallError(t, below, "triage_feedback_reset", nil); !strings.Contains(got,
		filepath.Join(notes, ".beads", "feedback.json")) {
		t.Errorf("reset below the root: %q, want a failure to write the folder's own file", got)
	}
	if got := feedbackCallError(t, below, "triage_feedback_record",
		map[string]string{"id": "api-1", "action": "accept"}); got !=
		"Error loading issues: failed to read beads directory: open "+
			filepath.Join(notes, ".beads")+": no such file or directory" {
		t.Errorf("accept api-1 below the root: %q", got)
	}
	if after, _ := os.ReadFile(filepath.Join(rootBeads, analysis.FeedbackFile)); string(after) != string(before) {
		t.Error("a command below the root changed the root's feedback.json")
	}
}

// TestFeedbackCommandInARepository: where a `.beads` is reachable nothing
// changes — the verdict lands in it, as an ordinary session's does.
func TestFeedbackCommandInARepository(t *testing.T) {
	fixFeedbackScoreClock(t, bvFeedbackRunDay)
	workspace := writableFeedbackFixture(t, "feedback")
	s := openFeedbackCommand(t, OpenConfig{Path: workspace})
	before := len(feedbackOnDisk(t, workspace).Events)
	got := call[feedbackRecordShape](t, s, "triage_feedback_record",
		map[string]string{"id": "fb-5", "action": "accept"})
	if got.Path != filepath.Join(workspace, ".beads", analysis.FeedbackFile) {
		t.Errorf("path = %s", got.Path)
	}
	if after := len(feedbackOnDisk(t, workspace).Events); after != before+1 {
		t.Errorf("events on disk %d -> %d, want one more", before, after)
	}
}

// TestFeedbackCommandSessionAnswersNothingElse: a session opened for the
// feedback flags may have loaded nothing, so it refuses any other method
// rather than answering over an empty graph.
func TestFeedbackCommandSessionAnswersNothingElse(t *testing.T) {
	s := openFeedbackCommand(t, OpenConfig{Path: discoveredFeedbackWorkspace(t)})
	if got := feedbackCallError(t, s, "triage", nil); !strings.Contains(got, "opened for feedback") {
		t.Errorf("triage: %q", got)
	}
}

// TestFeedbackRecordReadsTheFileFirst: bv loads feedback.json before it
// looks the bead up, so a file it cannot parse is the error even for a bead
// that does not exist.
func TestFeedbackRecordReadsTheFileFirst(t *testing.T) {
	workspace := writableFeedbackFixture(t, "feedback")
	if err := os.WriteFile(filepath.Join(workspace, ".beads", analysis.FeedbackFile),
		[]byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	for name, s := range map[string]*Session{
		"ordinary": openFeedback(t, workspace),
		"feedback": openFeedbackCommand(t, OpenConfig{Path: workspace}),
	} {
		got := feedbackCallError(t, s, "triage_feedback_record",
			map[string]string{"id": "no-such-bead", "action": "accept"})
		if !strings.HasPrefix(got, "Error loading feedback: failed to parse feedback file") {
			t.Errorf("%s session: %q, want bv's feedback load error", name, got)
		}
	}
}
