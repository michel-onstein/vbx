package engine

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// Uncommitted marks in a multi-repository workspace (vbx-d1c).
//
// `snapshot_at` opened the object store of the repository holding
// `.bv/workspace.yaml` and looked there for the members' beads, which live in
// repositories of their own. These tests build a workspace whose members are
// two separate git repositories and whose root is in none — the shape where
// the old path had nothing at all to compare against.

// memberRepo is one member's repository, committed through go-git.
type memberRepo struct {
	t    *testing.T
	dir  string
	tree *git.Worktree
	when time.Time
}

func initMember(t *testing.T, dir string) *memberRepo {
	t.Helper()
	repo, err := git.PlainInit(dir, false)
	if err != nil {
		t.Fatalf("init %s: %v", dir, err)
	}
	tree, err := repo.Worktree()
	if err != nil {
		t.Fatal(err)
	}
	return &memberRepo{t: t, dir: dir, tree: tree, when: time.Date(2026, 1, 1, 9, 0, 0, 0, time.UTC)}
}

func writeBeads(t *testing.T, dir string, lines ...string) {
	t.Helper()
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	content := ""
	for _, line := range lines {
		content += line + "\n"
	}
	if err := os.WriteFile(filepath.Join(beads, "issues.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (m *memberRepo) commitBeads(message string) {
	m.t.Helper()
	if _, err := m.tree.Add(".beads/issues.jsonl"); err != nil {
		m.t.Fatal(err)
	}
	m.when = m.when.Add(time.Hour)
	if _, err := m.tree.Commit(message, &git.CommitOptions{
		Author: &object.Signature{Name: "dev", Email: "dev@example.com", When: m.when},
	}); err != nil {
		m.t.Fatalf("commit: %v", err)
	}
}

func writeWorkspaceConfig(t *testing.T, root string, members ...string) {
	t.Helper()
	config := "name: Two repositories\nrepos:\n"
	for _, member := range members {
		config += "  - name: " + member + "\n    path: " + member + "\n    prefix: \"" + member + "-\"\n"
	}
	if err := os.MkdirAll(filepath.Join(root, ".bv"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".bv", "workspace.yaml"), []byte(config), 0o644); err != nil {
		t.Fatal(err)
	}
}

var (
	apiOne = bead("1", "API endpoint", "open")
	apiTwo = bead("2", "API docs", "open")
	webOne = bead("1", "Web form", "open")
)

// twoRepoWorkspace builds a workspace of two member repositories, each with
// its beads committed, under a root that is in no repository.
func twoRepoWorkspace(t *testing.T) (root string, api, web *memberRepo) {
	t.Helper()
	root = t.TempDir()
	api = initMember(t, filepath.Join(root, "api"))
	writeBeads(t, api.dir, apiOne, apiTwo)
	api.commitBeads("api beads")
	web = initMember(t, filepath.Join(root, "web"))
	writeBeads(t, web.dir, webOne)
	web.commitBeads("web beads")
	writeWorkspaceConfig(t, root, "api", "web")
	return root, api, web
}

type headSnapshot struct {
	ResolvedRevision string           `json:"resolved_revision"`
	Issues           []map[string]any `json:"issues"`
	UnknownIDs       []string         `json:"unknown_ids"`
	Repos            []memberHead     `json:"repos"`
}

// dirtyIDs is the app's comparison, in Go: a record differs from HEAD, or is
// not at HEAD at all. The origin is the app's own annotation, not part of the
// record, and the app's model has no field for it.
func dirtyIDs(t *testing.T, s *Session) (dirty []string, unknown []string) {
	t.Helper()
	head := call[headSnapshot](t, s, "snapshot_at", map[string]string{"revision": "HEAD"})
	working := call[struct {
		Issues []map[string]any `json:"issues"`
	}](t, s, "issues", nil)

	committed := map[string]map[string]any{}
	for _, issue := range head.Issues {
		delete(issue, "origin")
		committed[issue["id"].(string)] = issue
	}
	skip := map[string]bool{}
	for _, id := range head.UnknownIDs {
		skip[id] = true
	}
	dirty = []string{}
	for _, issue := range working.Issues {
		delete(issue, "origin")
		id := issue["id"].(string)
		if skip[id] {
			continue
		}
		if before, ok := committed[id]; !ok || !reflect.DeepEqual(before, issue) {
			dirty = append(dirty, id)
		}
	}
	sort.Strings(dirty)
	return dirty, head.UnknownIDs
}

func reloadSession(t *testing.T, s *Session) {
	t.Helper()
	if _, err := s.Call("reload", nil); err != nil {
		t.Fatalf("reload: %v", err)
	}
}

// The regression: an edit in one member marks exactly that bead, and a commit
// in that member — in its own repository — clears it.
func TestWorkspaceUncommittedMarksFollowEachMembersHead(t *testing.T) {
	root, _, web := twoRepoWorkspace(t)
	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	dirty, unknown := dirtyIDs(t, s)
	if len(dirty) != 0 || len(unknown) != 0 {
		t.Fatalf("a freshly committed workspace has dirty %v, unknown %v; want neither", dirty, unknown)
	}

	writeBeads(t, web.dir, bead("1", "Web form, renamed", "open"))
	reloadSession(t, s)
	dirty, _ = dirtyIDs(t, s)
	if !reflect.DeepEqual(dirty, []string{"web-1"}) {
		t.Fatalf("after editing web-1 the dirty set is %v, want [web-1]", dirty)
	}

	web.commitBeads("rename the form")
	dirty, _ = dirtyIDs(t, s)
	if len(dirty) != 0 {
		t.Fatalf("after committing in the member the dirty set is %v, want nothing", dirty)
	}

	// A bead added to the other member is "added": absent at that member's HEAD.
	writeBeads(t, filepath.Join(root, "api"), apiOne, apiTwo, bead("3", "API limits", "open"))
	reloadSession(t, s)
	dirty, _ = dirtyIDs(t, s)
	if !reflect.DeepEqual(dirty, []string{"api-3"}) {
		t.Fatalf("after adding api-3 the dirty set is %v, want [api-3]", dirty)
	}
}

// Each member's HEAD is named, and the committed records carry the loader's
// namespacing — the same ids the working set has.
func TestWorkspaceHeadSnapshotIsNamespacedPerMember(t *testing.T) {
	root, _, _ := twoRepoWorkspace(t)
	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	head := call[headSnapshot](t, s, "snapshot_at", nil)
	ids := []string{}
	for _, issue := range head.Issues {
		ids = append(ids, issue["id"].(string))
	}
	sort.Strings(ids)
	if want := []string{"api-1", "api-2", "web-1"}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("committed ids are %v, want %v", ids, want)
	}
	if len(head.Repos) != 2 {
		t.Fatalf("repos are %+v, want one entry per member", head.Repos)
	}
	for _, repo := range head.Repos {
		if repo.ResolvedRevision == "" || repo.Error != "" {
			t.Errorf("member %s did not resolve: %+v", repo.Name, repo)
		}
	}
	// Two repositories, two HEADs: no single commit describes the snapshot.
	if head.ResolvedRevision != "" {
		t.Errorf("resolved_revision is %q for two separate repositories, want empty", head.ResolvedRevision)
	}
}

// A member outside any repository has nothing to compare against. Its beads
// are reported as unknown — never as added, which is what leaving them out of
// the committed set would make them.
func TestWorkspaceMemberWithoutRepositoryIsUnknown(t *testing.T) {
	root := t.TempDir()
	api := initMember(t, filepath.Join(root, "api"))
	writeBeads(t, api.dir, apiOne)
	api.commitBeads("api beads")
	writeBeads(t, filepath.Join(root, "web"), webOne) // no repository
	writeWorkspaceConfig(t, root, "api", "web")

	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	dirty, unknown := dirtyIDs(t, s)
	if len(dirty) != 0 {
		t.Errorf("dirty set is %v, want nothing: web has no history to differ from", dirty)
	}
	if !reflect.DeepEqual(unknown, []string{"web-1"}) {
		t.Errorf("unknown ids are %v, want [web-1]", unknown)
	}
}

// With no member in a repository there is nothing to compare at all, and that
// is an error the app reads as "unknown" for the whole workspace.
func TestWorkspaceHeadSnapshotWithNoRepositoryIsAnError(t *testing.T) {
	root := multiRepoWorkspace(t)
	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	if _, err := s.Call("snapshot_at", nil); err == nil {
		t.Fatal("snapshot_at succeeded for a workspace with no repository behind any member")
	}
}

// Members that are subdirectories of one repository — a monorepo — resolve to
// the same commit, which is then reported as the snapshot's revision.
func TestWorkspaceMembersInOneRepositoryShareAHead(t *testing.T) {
	root := t.TempDir()
	repo := initMember(t, root)
	writeBeads(t, filepath.Join(root, "api"), apiOne)
	writeBeads(t, filepath.Join(root, "web"), webOne)
	for _, rel := range []string{"api/.beads/issues.jsonl", "web/.beads/issues.jsonl"} {
		if _, err := repo.tree.Add(rel); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := repo.tree.Commit("both", &git.CommitOptions{
		Author: &object.Signature{Name: "dev", Email: "dev@example.com", When: repo.when},
	}); err != nil {
		t.Fatal(err)
	}
	writeWorkspaceConfig(t, root, "api", "web")

	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	head := call[headSnapshot](t, s, "snapshot_at", nil)
	if head.ResolvedRevision == "" {
		t.Errorf("members of one repository did not report its commit: %+v", head.Repos)
	}
	if dirty, _ := dirtyIDs(t, s); len(dirty) != 0 {
		t.Errorf("dirty set is %v for a committed monorepo workspace", dirty)
	}

	got := call[struct {
		GitWatchPaths []string `json:"git_watch_paths"`
	}](t, s, "info", nil).GitWatchPaths
	if len(got) != 1 || realPath(t, got[0]) != realPath(t, filepath.Join(root, ".git")) {
		t.Errorf("git watch paths are %v, want the one shared .git", got)
	}
}

// A commit in a member moves that member's HEAD, which the app's watch on the
// root repository cannot see; the engine names every member's git directory.
func TestWorkspaceGitWatchPathsNameEachMembersRepository(t *testing.T) {
	root, _, _ := twoRepoWorkspace(t)
	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	raw, err := s.Call("info", nil)
	if err != nil {
		t.Fatal(err)
	}
	var info struct {
		GitWatchPaths []string `json:"git_watch_paths"`
	}
	if err := json.Unmarshal(raw, &info); err != nil {
		t.Fatal(err)
	}
	got := []string{}
	for _, p := range info.GitWatchPaths {
		got = append(got, realPath(t, p))
	}
	sort.Strings(got)
	r := realPath(t, root)
	want := []string{filepath.Join(r, "api", ".git"), filepath.Join(r, "web", ".git")}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("git watch paths are %v, want %v", got, want)
	}
}

// A single repository reports none: the app finds its git directory itself.
func TestSingleRepositoryHasNoGitWatchPaths(t *testing.T) {
	s := openHistorySession(t)
	info := call[struct {
		GitWatchPaths []string `json:"git_watch_paths"`
	}](t, s, "info", nil)
	if info.GitWatchPaths == nil || len(info.GitWatchPaths) != 0 {
		t.Fatalf("git_watch_paths is %v for a single repository, want an empty list", info.GitWatchPaths)
	}
}

// A linked worktree's `.git` is a file; the directory it points at is the one
// a commit there moves.
func TestGitDirOfFollowsAWorktreePointer(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "main", ".git", "worktrees", "topic")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	tree := filepath.Join(root, "topic")
	if err := os.MkdirAll(filepath.Join(tree, ".beads"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tree, ".git"), []byte("gitdir: "+target+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := gitDirOf(filepath.Join(tree, ".beads")); got != target {
		t.Fatalf("gitDirOf = %q, want %q", got, target)
	}
	if got := gitDirOf(t.TempDir()); got != "" {
		// t.TempDir is outside any repository on a normal machine; if the test
		// runner's temp dir is inside one, the walk finding it is correct.
		if _, err := os.Stat(got); err != nil {
			t.Fatalf("gitDirOf returned %q, which does not exist", got)
		}
	}
}

// Time travel in a multi-repository workspace (vbx-bcq, ADR-028).
//
// Every revision but HEAD went through the object store of the repository
// holding `.bv/workspace.yaml`, read the yaml as the bead set, and showed the
// root repository's view as if it were the workspace's: the scrubber offered
// commits that changed the yaml, and a diff against one called every bead new.
// The layout here is that worst case — a monorepo whose root commits the yaml
// beside both members — where every call used to *succeed*.
func TestWorkspaceTimeTravelIsRefusedRatherThanReadFromTheRoot(t *testing.T) {
	root := t.TempDir()
	repo := initMember(t, root)
	writeBeads(t, filepath.Join(root, "api"), apiOne)
	writeBeads(t, filepath.Join(root, "web"), webOne)
	writeWorkspaceConfig(t, root, "api", "web")
	for _, rel := range []string{"api/.beads/issues.jsonl", "web/.beads/issues.jsonl", ".bv/workspace.yaml"} {
		if _, err := repo.tree.Add(rel); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := repo.tree.Commit("workspace", &git.CommitOptions{
		Author: &object.Signature{Name: "dev", Email: "dev@example.com", When: repo.when},
	}); err != nil {
		t.Fatal(err)
	}

	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	refused := []struct{ method, request string }{
		{"revisions", `{}`},
		{"diff", `{"revision":"HEAD"}`},
		{"snapshot_at", `{"revision":"HEAD~0"}`},
	}
	for _, c := range refused {
		out, err := s.Call(c.method, []byte(c.request))
		if !errors.Is(err, errWorkspaceTimeTravel) {
			t.Errorf("%s %s = %s, %v; want the workspace refusal", c.method, c.request, out, err)
		}
	}

	// HEAD keeps its per-member meaning: the uncommitted marks read it.
	head := call[headSnapshot](t, s, "snapshot_at", map[string]string{"revision": "HEAD"})
	if head.ResolvedRevision == "" {
		t.Errorf("snapshot_at HEAD lost its per-member answer: %+v", head.Repos)
	}
}

// A single repository is unaffected by the refusal.
func TestSingleRepositoryTimeTravelIsNotRefused(t *testing.T) {
	root := t.TempDir()
	repo := initMember(t, root)
	writeBeads(t, root, apiOne)
	repo.commitBeads("beads")

	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	for _, method := range []string{"revisions", "diff"} {
		if _, err := s.Call(method, []byte(`{"revision":"HEAD"}`)); err != nil {
			t.Errorf("%s: %v", method, err)
		}
	}
}
