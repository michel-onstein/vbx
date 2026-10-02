package engine

import (
	"context"
	"database/sql"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/workspace"
)

type withLoadStderr struct {
	LoadStderr []string `json:"load_stderr"`
	Warnings   []string `json:"warnings"`
}

// bv 0.25.2 over Fixtures/dropped, measured outside robot mode: both of the
// loader's warnings, before anything the command prints. vbx-1l6.
func TestLoadStderrIsBvsInteractiveWarnings(t *testing.T) {
	s, err := Open(OpenConfig{Path: droppedFixturePath(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	got := call[withLoadStderr](t, s, "info", nil).LoadStderr
	want := []string{"Warning: " + droppedWarnings[0], "Warning: " + droppedWarnings[1]}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("load_stderr = %q, want %q", got, want)
	}
}

// A clean load prints nothing — and reports an empty list, not a missing one.
func TestLoadStderrIsEmptyOverACleanLoad(t *testing.T) {
	s, err := Open(OpenConfig{Path: newFixtureWorkspace(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	got := call[map[string]any](t, s, "info", nil)["load_stderr"]
	if lines, ok := got.([]any); !ok || len(lines) != 0 {
		t.Errorf("load_stderr = %#v, want []", got)
	}
}

// bv replays every warning of the selected source; only the LoadReport (and
// so load_stats) keeps ten. Twelve malformed lines print twelve warnings.
func TestLoadStderrIsUncapped(t *testing.T) {
	dir := newFixtureWorkspace(t)
	file, err := os.OpenFile(filepath.Join(dir, ".beads", "issues.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(strings.Repeat("{\"id\": \"cut-off\",\n", 12)); err != nil {
		t.Fatal(err)
	}
	file.Close()

	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	if got := call[withLoadStderr](t, s, "info", nil).LoadStderr; len(got) != 12 {
		t.Errorf("load_stderr has %d lines, want all 12: %q", len(got), got)
	}
}

// bv's SQLite reader counts the rows it drops and prints none of them; vbx's
// keeps them as warnings for the app, and must not print them either.
func TestLoadStderrIsEmptyOverABeadsDB(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".beads"), 0o755); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", "file:"+filepath.Join(dir, ".beads", "beads.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`CREATE TABLE issues (id TEXT, title TEXT, status TEXT, created_at TEXT, updated_at TEXT)`,
		`INSERT INTO issues VALUES
			('k-1','Kept','open','2026-08-01T09:00:00Z','2026-08-02T09:00:00Z'),
			('k-2','Backwards','open','2026-08-05T09:00:00Z','2026-08-01T09:00:00Z')`,
	} {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("exec %q: %v", stmt, err)
		}
	}
	db.Close()

	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	got := call[withLoadStderr](t, s, "info", nil)
	if len(got.Warnings) == 0 {
		t.Fatal("the beads.db dropped no row; the test proves nothing")
	}
	if len(got.LoadStderr) != 0 {
		t.Errorf("load_stderr = %q over a beads.db, want nothing", got.LoadStderr)
	}
}

// A leftover merge artifact is a discovery warning, which bv prints before the
// parse's; vbx's own fallback note ("issues.jsonl is empty") it does not.
func TestLoadStderrCarriesDiscoveryWarnings(t *testing.T) {
	dir := newFixtureWorkspace(t)
	artifact := filepath.Join(dir, ".beads", "beads.left.jsonl")
	if err := os.WriteFile(artifact, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	got := call[withLoadStderr](t, s, "info", nil).LoadStderr
	if len(got) != 1 || !strings.HasPrefix(got[0], "Warning: Merge artifact files detected: ") {
		t.Errorf("load_stderr = %q, want bv's merge-artifact warning", got)
	}
}

// Over a workspace, each member's warnings are bv's own loader's — captured
// from bv's stderr here, on the same files — and a member that failed adds
// cmd/bv's summary after them.
func TestWorkspaceLoadStderrMatchesBv(t *testing.T) {
	root := multiRepoWorkspace(t)
	web := filepath.Join(root, "web", ".beads", "issues.jsonl")
	file, err := os.OpenFile(web, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("not json\n{\"id\": \"cut-off\",\n"); err != nil {
		t.Fatal(err)
	}
	file.Close()
	config := filepath.Join(root, ".bv", "workspace.yaml")
	appendFile(t, config, "  - name: gone\n    path: gone\n    prefix: \"gone-\"\n")

	bvLines := captureStderr(t, func() {
		if _, _, err := workspace.LoadAllFromConfig(context.Background(), config); err != nil {
			t.Fatal(err)
		}
	})

	if len(bvLines) != 2 {
		t.Fatalf("bv printed %q, want web's two warnings", bvLines)
	}
	summary := []string{"Warning: 1 repos failed to load", "  - gone"}
	// Discovered from the folder, the workspace is announced first; named
	// with --workspace, it is not.
	notice := "No .beads directory found; using workspace " + config
	for _, c := range []struct {
		name string
		open OpenConfig
		want []string
	}{
		{"discovered", OpenConfig{Path: root, SkipPhase2: true},
			append(append([]string{notice}, bvLines...), summary...)},
		{"--workspace", OpenConfig{Path: root, Workspace: config, SkipPhase2: true},
			append(slices.Clone(bvLines), summary...)},
	} {
		s, err := Open(c.open)
		if err != nil {
			t.Fatal(err)
		}
		// bv loads members in parallel, so only each member's order is
		// fixed; this workspace's warnings are all web's, in file order.
		if got := call[withLoadStderr](t, s, "info", nil).LoadStderr; !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: load_stderr = %q, want %q", c.name, got, c.want)
		}
		s.Close()
	}
}

// The failure summary is cmd/bv's, word for word, and absent when nothing failed.
func TestWorkspaceFailureStderr(t *testing.T) {
	if got := workspaceFailureStderr(workspace.LoadSummary{}); got != nil {
		t.Errorf("no failures printed %q", got)
	}
	got := workspaceFailureStderr(workspace.LoadSummary{FailedRepos: 2, FailedRepoNames: []string{"a", "b"}})
	want := []string{"Warning: 2 repos failed to load", "  - a", "  - b"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
}

func appendFile(t *testing.T, path, text string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(text); err != nil {
		t.Fatal(err)
	}
}

// captureStderr runs fn with os.Stderr redirected and returns its lines.
func captureStderr(t *testing.T, fn func()) []string {
	t.Helper()
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stderr
	os.Stderr = write
	done := make(chan []byte)
	go func() {
		data, _ := io.ReadAll(read)
		done <- data
	}()
	func() {
		defer func() { os.Stderr = saved }()
		fn()
	}()
	write.Close()
	text := strings.TrimRight(string(<-done), "\n")
	if text == "" {
		return nil
	}
	return strings.Split(text, "\n")
}
