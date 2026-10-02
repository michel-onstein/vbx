package engine

import (
	"os"
	"path/filepath"
	"testing"
)

// watchPathsOf reads a payload's watch list, with symlinks resolved so a
// temporary directory under /var compares equal to its /private/var self.
func watchPathsOf(t *testing.T, s *Session, method string) []string {
	t.Helper()
	info := call[struct {
		WatchPaths []string `json:"watch_paths"`
	}](t, s, method, nil)
	if info.WatchPaths == nil {
		t.Fatalf("%s: watch_paths came back null rather than a list", method)
	}
	resolved := make([]string, 0, len(info.WatchPaths))
	for _, p := range info.WatchPaths {
		resolved = append(resolved, realPath(t, p))
	}
	return resolved
}

func realPath(t *testing.T, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatalf("resolving %s: %v", p, err)
	}
	return r
}

func containsPath(list []string, want string) bool {
	for _, p := range list {
		if p == want {
			return true
		}
	}
	return false
}

// The app watched only `.bv/` for a workspace, because that is the directory
// of the session's source — so an edit to any member's beads, or to the root
// feedback.json, never reloaded anything (vbx-zot). The engine now names every
// directory the session reads from.
func TestWorkspaceWatchPathsCoverEveryMember(t *testing.T) {
	root := multiRepoWorkspace(t)
	// The root's own .beads holds feedback.json, which triage reads.
	if err := os.MkdirAll(filepath.Join(root, ".beads"), 0o755); err != nil {
		t.Fatal(err)
	}
	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	got := watchPathsOf(t, s, "info")
	r := realPath(t, root)
	for _, want := range []string{
		filepath.Join(r, ".bv"),
		filepath.Join(r, ".beads"),
		filepath.Join(r, "api", ".beads"),
		filepath.Join(r, "web", ".beads"),
	} {
		if !containsPath(got, want) {
			t.Errorf("watch paths %v do not include %s", got, want)
		}
	}
	if len(got) != 4 {
		t.Errorf("watch paths are %v, want exactly the four directories read", got)
	}
}

// A directory that does not exist is not listed: a watch on it never fires.
func TestWorkspaceWatchPathsSkipMissingDirectories(t *testing.T) {
	root := multiRepoWorkspace(t) // no root .beads
	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	got := watchPathsOf(t, s, "info")
	if containsPath(got, filepath.Join(realPath(t, root), ".beads")) {
		t.Errorf("watch paths %v include a root .beads that does not exist", got)
	}
}

// Adding a member changes which directories are read even when it adds no
// bead, and the hash-gated "unchanged" path must still report the new list —
// otherwise the app never watches the new member.
func TestWorkspaceReloadReportsANewMemberUnchanged(t *testing.T) {
	root := multiRepoWorkspace(t)
	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	docs := filepath.Join(root, "docs", ".beads")
	if err := os.MkdirAll(docs, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docs, "issues.jsonl"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	config := `name: Demo workspace
repos:
  - name: api
    path: api
    prefix: "api-"
  - name: web
    path: web
    prefix: "web-"
  - name: docs
    path: docs
    prefix: "docs-"
`
	if err := os.WriteFile(filepath.Join(root, ".bv", "workspace.yaml"), []byte(config), 0o644); err != nil {
		t.Fatal(err)
	}

	reloaded := call[struct {
		Changed    bool     `json:"changed"`
		WatchPaths []string `json:"watch_paths"`
	}](t, s, "reload", nil)
	if reloaded.Changed {
		t.Fatal("precondition: a member with no beads should leave the hash alone")
	}
	want := filepath.Join(realPath(t, root), "docs", ".beads")
	found := false
	for _, p := range reloaded.WatchPaths {
		if realPath(t, p) == want {
			found = true
		}
	}
	if !found {
		t.Errorf("watch paths %v do not include the new member", reloaded.WatchPaths)
	}
}

func TestSingleRepoWatchesItsSourceDirectory(t *testing.T) {
	s := openFixture(t)
	info := call[struct {
		Source     string   `json:"source"`
		WatchPaths []string `json:"watch_paths"`
	}](t, s, "info", nil)
	if len(info.WatchPaths) != 1 || info.WatchPaths[0] != filepath.Dir(info.Source) {
		t.Errorf("watch paths are %v, want just %s", info.WatchPaths, filepath.Dir(info.Source))
	}
}
