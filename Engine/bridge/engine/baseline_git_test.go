package engine

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/baseline"
	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
)

// standInGit puts a stand-in `git` first on PATH that appends its arguments
// to the returned file, which exists only once it has run.
func standInGit(t *testing.T) (runs string) {
	t.Helper()
	bin := t.TempDir()
	runs = filepath.Join(bin, "runs")
	script := "#!/bin/sh\necho \"git $@\" >> '" + runs + "'\nexit 1\n"
	if err := os.WriteFile(filepath.Join(bin, "git"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return runs
}

// Regression (vbx-6s8): baseline_save built the baseline with bv's
// baseline.New, which runs `git` three times. The app may not spawn a
// process (ADR-006, App Sandbox), so the stand-in must record no run.
func TestBaselineSaveSpawnsNoGit(t *testing.T) {
	dir := historyRepo(t)
	runs := standInGit(t)
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	call[baselineShape](t, s, "baseline_save", map[string]any{"description": "no git"})

	if _, err := os.Stat(runs); err == nil {
		recorded, _ := os.ReadFile(runs)
		t.Fatalf("baseline_save spawned git: %q", recorded)
	}
}

// Regression (vbx-6s8): the git that baseline.New ran was run in the
// process's working directory, so a baseline recorded whichever repository
// the process happened to sit in. It must be the workspace's HEAD.
func TestBaselineRecordsTheWorkspaceCommitNotTheProcesses(t *testing.T) {
	dir := historyRepo(t)
	want, err := git.PlainOpen(dir)
	if err != nil {
		t.Fatal(err)
	}
	head, err := want.Head()
	if err != nil {
		t.Fatal(err)
	}

	// The process sits in another repository, with a commit of its own.
	elsewhere := newRepo(t)
	elsewhere.write("README", "another repository\n")
	other := elsewhere.commit("A commit in some other repository", "eve")
	t.Chdir(elsewhere.dir)

	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	call[baselineShape](t, s, "baseline_save", map[string]any{"description": "here"})

	saved, err := baseline.Load(baseline.DefaultPath(dir))
	if err != nil {
		t.Fatal(err)
	}
	if saved.CommitSHA == other {
		t.Fatalf("the baseline recorded the process's repository: %s", other)
	}
	if saved.CommitSHA != head.Hash().String() {
		t.Errorf("commit_sha %q, want the workspace's HEAD %s", saved.CommitSHA, head.Hash())
	}
	if saved.CommitMessage != "Mark the loader rewrite done" {
		t.Errorf("commit_message %q", saved.CommitMessage)
	}
	if saved.Branch != head.Name().Short() {
		t.Errorf("branch %q, want %q", saved.Branch, head.Name().Short())
	}
	if saved.Version != baseline.CurrentVersion || saved.Description != "here" {
		t.Errorf("version %d, description %q", saved.Version, saved.Description)
	}
}

// workspaceGitInfo is a port of three git commands, so it is checked against
// git itself: a multi-line subject, a subdirectory, a detached HEAD, an
// unborn HEAD and no repository at all.
func TestWorkspaceGitInfoMatchesGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	gitSays := func(dir string, args ...string) string {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
		out, err := cmd.Output()
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(out))
	}
	check := func(name, dir string) {
		t.Helper()
		sha, message, branch := workspaceGitInfo(dir)
		if want := gitSays(dir, "rev-parse", "HEAD"); sha != want {
			t.Errorf("%s: sha %q, git says %q", name, sha, want)
		}
		if want := gitSays(dir, "log", "-1", "--format=%s"); message != want {
			t.Errorf("%s: message %q, git says %q", name, message, want)
		}
		if want := gitSays(dir, "rev-parse", "--abbrev-ref", "HEAD"); branch != want {
			t.Errorf("%s: branch %q, git says %q", name, branch, want)
		}
	}

	b := newRepo(t)
	b.write("src/a.go", "package src\n")
	first := b.commit("\n\n  Wrap a subject  \nacross two lines\t\n\nThe body.\n", "ada")
	b.write("src/b.go", "package src\n")
	b.commit("Second commit\n", "ada")
	check("branch", b.dir)
	check("subdirectory", filepath.Join(b.dir, "src"))

	if err := b.tree.Checkout(&git.CheckoutOptions{Hash: plumbing.NewHash(first)}); err != nil {
		t.Fatal(err)
	}
	check("detached", b.dir)

	unborn := t.TempDir()
	if _, err := git.PlainInit(unborn, false); err != nil {
		t.Fatal(err)
	}
	check("unborn", unborn)

	sha, message, branch := workspaceGitInfo(t.TempDir())
	if sha != "" || message != "" || branch != "" {
		t.Errorf("no repository: %q %q %q", sha, message, branch)
	}
}

func TestCommitSubjectIsGitsPercentS(t *testing.T) {
	for message, want := range map[string]string{
		"One line":                     "One line",
		"One line\n":                   "One line",
		"Two\nlines\n\nbody":           "Two lines",
		"\n\n  Lead  \nnext\t\n\nbody": "Lead next",
		"Subject\r\n\r\nbody":          "Subject",
		"":                             "",
		"\n\n\n":                       "",
	} {
		if got := commitSubject(message); got != want {
			t.Errorf("commitSubject(%q) = %q, want %q", message, got, want)
		}
	}
}
