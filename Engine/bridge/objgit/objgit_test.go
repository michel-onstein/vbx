package objgit

import (
	"bytes"
	"context"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// These tests are the package's contract: every command line it answers is
// run through real git on the same repository, and the bytes must match.
// Tests may spawn git; the package never does.

const (
	walkFormat   = "%x1e%H%x00%aI%x00%an%x00%ae%x00%s%x00%b%x1f"
	headerFormat = "%H%x00%aI%x00%an%x00%ae%x00%s"
)

var excludes = []string{"--", ".",
	":(exclude,glob).beads/**", ":(exclude,glob).bv/**", ":(exclude,glob).git/**",
	":(exclude,glob)node_modules/**", ":(exclude,glob)vendor/**",
	":(exclude,glob)__pycache__/**", ":(exclude,glob).venv/**", ":(exclude,glob)venv/**"}

// testRepo is a repository built by real git with pinned identities and
// dates, so its hashes are the same on every run.
type testRepo struct {
	t   *testing.T
	dir string
	day int
}

func newRepo(t *testing.T) *testRepo {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	r := &testRepo{t: t, dir: t.TempDir()}
	r.git("init", "-q", "-b", "main")
	return r
}

func gitEnv() []string {
	return append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
		"LC_ALL=C")
}

func (r *testRepo) git(args ...string) string {
	r.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = r.dir
	cmd.Env = gitEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		r.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

// mv renames a tracked file, creating the destination's directory.
func (r *testRepo) mv(from, to string) {
	r.t.Helper()
	if err := os.MkdirAll(filepath.Join(r.dir, filepath.Dir(to)), 0o755); err != nil {
		r.t.Fatal(err)
	}
	r.git("mv", from, to)
}

func (r *testRepo) write(path, content string) {
	r.t.Helper()
	full := filepath.Join(r.dir, path)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		r.t.Fatal(err)
	}
}

// commit stages everything and commits it as the given author, a day after
// the last commit unless at names the moment ("2026-08-03T10:00:00+02:00").
func (r *testRepo) commit(author, message, at string) {
	r.t.Helper()
	r.day++
	if at == "" {
		at = fmt.Sprintf("2026-07-%02dT10:00:00Z", r.day)
	}
	name, email := "Ada Lovelace", "ada@example.com"
	if author == "alan" {
		name, email = "Alan Turing", "alan@example.com"
	}
	r.git("add", "-A")
	cmd := exec.Command("git", "commit", "-q", "--allow-empty", "-F", "-")
	cmd.Dir = r.dir
	cmd.Stdin = strings.NewReader(message)
	cmd.Env = append(gitEnv(),
		"GIT_AUTHOR_NAME="+name, "GIT_AUTHOR_EMAIL="+email, "GIT_AUTHOR_DATE="+at,
		"GIT_COMMITTER_NAME="+name, "GIT_COMMITTER_EMAIL="+email, "GIT_COMMITTER_DATE="+at)
	if out, err := cmd.CombinedOutput(); err != nil {
		r.t.Fatalf("commit %q: %v\n%s", message, err, out)
	}
}

// compare runs one command line through git and through Run and requires
// the same stdout and the same success or failure.
func compare(t *testing.T, dir string, stdin string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = gitEnv()
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	want, gitErr := cmd.Output()

	var got bytes.Buffer
	var in *strings.Reader
	if stdin != "" {
		in = strings.NewReader(stdin)
	}
	var runErr error
	if in != nil {
		runErr = Run(context.Background(), dir, args, in, &got)
	} else {
		runErr = Run(context.Background(), dir, args, nil, &got)
	}
	if (gitErr != nil) != (runErr != nil) {
		t.Fatalf("git %q: git error %v, objgit error %v", args, gitErr, runErr)
	}
	if gitErr != nil {
		return
	}
	if !bytes.Equal(want, got.Bytes()) {
		t.Fatalf("git %q differs\n--- git\n%q\n--- objgit\n%q", args, want, got.Bytes())
	}
}

// gitShows asserts what real git prints for a command line contains want,
// so a scenario cannot quietly stop exercising what it was built for.
func gitShows(t *testing.T, r *testRepo, want string, args ...string) {
	t.Helper()
	if out := r.git(args...); !strings.Contains(out, want) {
		t.Fatalf("git %q does not show %q; the scenario no longer tests it:\n%s", args, want, out)
	}
}

// bvLogs are the command lines bv's correlator runs against a repository,
// with the filters it can add.
func bvLogs(t *testing.T, r *testRepo, beadsPath string) {
	t.Helper()
	filters := [][]string{
		nil,
		{"-n3"},
		{"-n1"},
		{"--since=2026-07-04T00:00:00Z"},
		{"--until=2026-07-05T12:00:00Z"},
		{"--since=2026-07-02T00:00:00Z", "--until=2026-07-08T00:00:00Z", "-n2"},
	}
	for _, f := range filters {
		walk := append([]string{"-c", "color.ui=false", "log", "--no-merges", "--name-only",
			"--format=" + walkFormat}, f...)
		compare(t, r.dir, "", walk...)

		snapshot := append([]string{"-c", "color.ui=false", "log", "--raw", "--no-abbrev",
			"--follow", "--format=" + headerFormat}, f...)
		compare(t, r.dir, "", append(snapshot, "--", beadsPath)...)

		causal := append([]string{"-c", "color.ui=false", "log", "--first-parent",
			"--diff-merges=first-parent", "--raw", "--no-abbrev", "--follow",
			"--format=" + headerFormat + "%x00%cI"}, f...)
		compare(t, r.dir, "", append(causal, "--", beadsPath)...)
	}

	// Every commit, in walk order and reversed, with a repeat, through both
	// batch passes.
	shas := strings.Fields(r.git("rev-list", "--all"))
	reversed := make([]string, len(shas))
	for i, s := range shas {
		reversed[len(shas)-1-i] = s
	}
	for _, list := range [][]string{shas, reversed, append([]string{shas[0]}, shas...)} {
		for _, diff := range []string{"--name-status", "--numstat"} {
			args := append([]string{"-c", "color.ui=false", "log", "--no-walk=unsorted", diff,
				"--format=" + headerFormat}, list...)
			compare(t, r.dir, "", append(args, excludes...)...)
		}
	}

	compare(t, r.dir, "", "rev-parse", "HEAD")
	compare(t, r.dir, "", "cat-file", "-s", "HEAD:"+beadsPath)
	for _, sha := range shas {
		compare(t, r.dir, "", "show", "-s", "--format=%aI%x00%cI", sha)
		showDiffs(t, r, sha)
	}

	// Every blob any commit's beads file had, a tree, a commit, and a name
	// that does not exist.
	var batch strings.Builder
	for _, sha := range shas {
		out := r.git("ls-tree", "-r", sha)
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			fields := strings.Fields(line)
			if len(fields) >= 3 {
				batch.WriteString(fields[2] + "\n")
			}
		}
	}
	batch.WriteString(shas[0] + "\n")
	batch.WriteString(strings.TrimSpace(r.git("rev-parse", "HEAD^{tree}")) + "\n")
	batch.WriteString("0123456789012345678901234567890123456789\n")
	compare(t, r.dir, batch.String(), "cat-file", "--batch")
}

// showDiffs compares the co-commit extractor's per-commit fallback — `git
// show --name-status|--numstat --format= <sha> -- . <excludes>` — for one
// commit, with and without the pathspec (vbx-lh0).
func showDiffs(t *testing.T, r *testRepo, rev string) {
	t.Helper()
	for _, diff := range []string{"--name-status", "--numstat"} {
		compare(t, r.dir, "", append([]string{"show", diff, "--format=", rev}, excludes...)...)
		compare(t, r.dir, "", "-c", "color.ui=false", "show", diff, "--format=", rev)
	}
}

func beadsLine(id, status string) string {
	return fmt.Sprintf(`{"id":%q,"title":"Bead %s","status":%q,"issue_type":"task","priority":2}`,
		id, id, status) + "\n"
}

func TestLinearHistoryMatchesGit(t *testing.T) {
	r := newRepo(t)
	r.write(".beads/issues.jsonl", beadsLine("b-1", "open"))
	r.write("README.md", "hello\n")
	r.write("src/parser.go", "package src\n\nfunc Parse() {}\n")
	r.commit("ada", "Initial import\n", "")

	r.write(".beads/issues.jsonl", beadsLine("b-1", "in_progress")+beadsLine("b-2", "open"))
	r.write("src/parser.go", "package src\n\nfunc Parse() int { return 1 }\n")
	r.commit("ada", "b-1: start the parser\n\nA body paragraph\nwith two lines.\n\nAnd a second.\n", "")

	r.write("src/lexer.go", "package src\n")
	r.commit("alan", "\n\n  Leading blank lines  \nand a wrapped   \nsubject\n\nbody\n", "2026-07-03T10:00:00+02:00")

	r.write(".beads/issues.jsonl", beadsLine("b-1", "closed")+beadsLine("b-2", "open"))
	r.commit("ada", "Close b-1", "2026-07-04T09:30:00-07:00")

	r.commit("alan", "An empty commit\n", "")

	if err := os.Remove(filepath.Join(r.dir, "README.md")); err != nil {
		t.Fatal(err)
	}
	r.write("node_modules/x/index.js", "x\n")
	r.write("lib/node_modules/y.js", "y\n")
	r.write("vendor/v.go", "package v\n")
	r.write(".bv/baseline.json", "{}\n")
	r.write("docs/guide.md", "line one\nline two\nline three\n")
	r.commit("alan", "Excluded and included paths\n", "")

	r.write("docs/guide.md", "line one\nline 2\nline three\nline four")
	r.write("bin/blob.dat", "a\x00b\x00c\n")
	r.commit("ada", "Binary file and no final newline\n", "")

	bvLogs(t, r, ".beads/issues.jsonl")
}

func TestRenamesMatchGit(t *testing.T) {
	r := newRepo(t)
	body := strings.Repeat("a line of the parser that stays the same\n", 30)
	others := ""
	for i := 2; i <= 9; i++ {
		others += beadsLine(fmt.Sprintf("r-%d", i), "open")
	}
	r.write(".beads/beads.jsonl", beadsLine("r-1", "open")+others)
	r.write("src/parser.go", body)
	r.write("src/util/strings.go", "package util\n"+body)
	r.write("one/same.txt", "same basename\n"+body)
	r.write("docs/a.md", body+"tail\n")
	r.commit("ada", "Initial\n", "")

	// An exact rename, an inexact one, a move keeping the basename, and a
	// rename beside an unrelated addition.
	r.mv("src/parser.go", "src/parse/parser.go")
	r.mv("src/util/strings.go", "src/text.go")
	r.write("src/text.go", "package text\n"+body+"one more line\n")
	r.mv("one/same.txt", "two/same.txt")
	r.write("two/same.txt", "same basename, edited\n"+body)
	r.write("new.txt", "brand new\n")
	r.commit("alan", "Move things around\n", "")

	// The beads file renamed and edited in the same commit, as br's
	// beads.jsonl to issues.jsonl migration does.
	r.mv(".beads/beads.jsonl", ".beads/issues.jsonl")
	r.write(".beads/issues.jsonl", beadsLine("r-1", "in_progress")+others)
	r.commit("ada", "Migrate the beads file\n", "")

	r.write(".beads/issues.jsonl", beadsLine("r-1", "closed")+others)
	r.write("docs/b.md", strings.Repeat("a line of the parser that stays the same\n", 30)+"tail\n")
	r.commit("ada", "Copy a doc, close r-1\n", "")

	// A mode change, a symlink and a typechange.
	if err := os.Chmod(filepath.Join(r.dir, "src/text.go"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("docs/a.md", filepath.Join(r.dir, "link.md")); err != nil {
		t.Fatal(err)
	}
	r.commit("alan", "Modes\n", "")
	if err := os.Remove(filepath.Join(r.dir, "link.md")); err != nil {
		t.Fatal(err)
	}
	r.write("link.md", "now a file\n")
	r.commit("alan", "Typechange\n", "")

	nameStatus := []string{"log", "--name-status", "--format=%s"}
	gitShows(t, r, "R100\tsrc/parser.go\tsrc/parse/parser.go", nameStatus...)
	gitShows(t, r, "\tsrc/util/strings.go\tsrc/text.go", nameStatus...)
	gitShows(t, r, "\tone/same.txt\ttwo/same.txt", nameStatus...)
	gitShows(t, r, "T\tlink.md", nameStatus...)
	gitShows(t, r, "src/{util/strings.go => text.go}", "log", "--numstat", "--format=%s")
	gitShows(t, r, "\t.beads/beads.jsonl\t.beads/issues.jsonl",
		"log", "--raw", "--follow", "--format=%s", "--", ".beads/issues.jsonl")

	bvLogs(t, r, ".beads/issues.jsonl")
}

func TestFollowsACopiedBeadsFile(t *testing.T) {
	r := newRepo(t)
	content := beadsLine("c-1", "open") + beadsLine("c-2", "open") + beadsLine("c-3", "open")
	r.write(".beads/beads.jsonl", content)
	r.write("main.go", "package main\n")
	r.commit("ada", "Initial\n", "")
	// issues.jsonl appears as a near copy while beads.jsonl stays: --follow
	// finds it through the copy search.
	r.write(".beads/issues.jsonl", content+beadsLine("c-4", "open"))
	r.commit("ada", "Start issues.jsonl\n", "")
	r.write(".beads/issues.jsonl", content+beadsLine("c-4", "closed"))
	r.commit("ada", "Close c-4\n", "")

	gitShows(t, r, "\t.beads/beads.jsonl\t.beads/issues.jsonl",
		"log", "--raw", "--follow", "--format=%s", "--", ".beads/issues.jsonl")
	gitShows(t, r, " C0", "log", "--raw", "--follow", "--format=%s", "--", ".beads/issues.jsonl")

	bvLogs(t, r, ".beads/issues.jsonl")
}

func TestMergesAndEqualDatesMatchGit(t *testing.T) {
	r := newRepo(t)
	r.write(".beads/issues.jsonl", beadsLine("m-1", "open"))
	r.write("a.txt", "a\n")
	r.commit("ada", "Root\n", "2026-07-01T10:00:00Z")

	r.git("checkout", "-q", "-b", "side")
	r.write("side.txt", "side\n")
	r.write(".beads/issues.jsonl", beadsLine("m-1", "in_progress"))
	r.commit("alan", "Side work on m-1\n", "2026-07-02T10:00:00Z")
	r.write("side.txt", "side 2\n")
	r.commit("alan", "More side work\n", "2026-07-03T10:00:00Z")

	r.git("checkout", "-q", "main")
	r.write("main.txt", "main\n")
	r.commit("ada", "Main work\n", "2026-07-02T10:00:00Z")
	r.write("main2.txt", "main\n")
	r.commit("ada", "Same moment as a side commit\n", "2026-07-03T10:00:00Z")

	cmd := exec.Command("git", "merge", "-q", "--no-ff", "-m", "Merge side", "side")
	cmd.Dir = r.dir
	cmd.Env = append(gitEnv(),
		"GIT_AUTHOR_NAME=Ada", "GIT_AUTHOR_EMAIL=ada@example.com",
		"GIT_AUTHOR_DATE=2026-07-04T10:00:00Z",
		"GIT_COMMITTER_NAME=Ada", "GIT_COMMITTER_EMAIL=ada@example.com",
		"GIT_COMMITTER_DATE=2026-07-04T10:00:00Z")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("merge: %v\n%s", err, out)
	}
	r.day = 4
	r.write(".beads/issues.jsonl", beadsLine("m-1", "closed"))
	r.commit("ada", "Close m-1\n", "")

	bvLogs(t, r, ".beads/issues.jsonl")
}

// merge runs `git merge` with a pinned identity and date, leaving the
// result uncommitted when the arguments ask for --no-commit.
func (r *testRepo) merge(args ...string) {
	r.t.Helper()
	cmd := exec.Command("git", append([]string{"merge", "-q"}, args...)...)
	cmd.Dir = r.dir
	at := fmt.Sprintf("2026-07-%02dT12:00:00Z", r.day)
	cmd.Env = append(gitEnv(),
		"GIT_AUTHOR_NAME=Ada", "GIT_AUTHOR_EMAIL=ada@example.com", "GIT_AUTHOR_DATE="+at,
		"GIT_COMMITTER_NAME=Ada", "GIT_COMMITTER_EMAIL=ada@example.com", "GIT_COMMITTER_DATE="+at)
	if out, err := cmd.CombinedOutput(); err != nil {
		r.t.Fatalf("merge %v: %v\n%s", args, err, out)
	}
}

// The orphan detector asks `git show --name-status` for a commit its walk
// listed no files for — an empty commit, such as this repository's own root
// — and objgit refused it, so --robot-orphans failed outright (vbx-lh0).
// Every shape of commit show can be asked about: an empty root, a root with
// files, an empty commit later on, renames, binary and quoted paths, and
// merges, where show prints a combined diff for --name-status and the
// first-parent diff for --numstat.
func TestShowDiffMatchesGit(t *testing.T) {
	r := newRepo(t)
	r.commit("ada", "Initial empty commit\n", "")
	showDiffs(t, r, "HEAD")

	body := strings.Repeat("a line that the rename keeps\n", 20)
	r.write(".beads/issues.jsonl", beadsLine("s-1", "open"))
	r.write("a.txt", "one\ntwo\nthree\nfour\nfive\n")
	r.write("b.txt", "b\n")
	r.write("bin.dat", "a\x00b\n")
	r.write("sp ace é.txt", "x\n")
	r.write("lib/x.go", "package lib\n"+body)
	r.write("node_modules/m.js", "m\n")
	r.write("shared.txt", "shared\n")
	r.commit("ada", "Files\n", "")
	r.commit("alan", "Empty in the middle\n", "")

	r.git("checkout", "-q", "-b", "side")
	r.write("a.txt", "ONE\ntwo\nthree\nfour\nfive\n")
	r.mv("lib/x.go", "pkg/x.go")
	if err := os.Remove(filepath.Join(r.dir, "b.txt")); err != nil {
		t.Fatal(err)
	}
	r.write("side.txt", "side\n")
	r.write("shared.txt", "shared, from the side\n")
	r.commit("alan", "Side\n", "")

	r.git("checkout", "-q", "main")
	r.write("a.txt", "one\ntwo\nthree\nfour\nFIVE\n")
	r.write("main.txt", "main\n")
	r.write("bin.dat", "a\x00c\n")
	r.write("node_modules/m.js", "m2\n")
	r.commit("ada", "Main\n", "")
	mainWork := strings.TrimSpace(r.git("rev-parse", "HEAD"))

	// A merge that edits beyond both sides: a.txt carries both edits and a
	// line of its own, evil.txt is new, the quoted path changes, and main's
	// main.txt is deleted. shared.txt is taken from the side wholesale.
	r.merge("--no-ff", "--no-commit", "side")
	r.write("a.txt", "ONE\ntwo\nthree\nfour\nFIVE\nsix\n")
	r.write("evil.txt", "evil\n")
	r.write("sp ace é.txt", "y\n")
	if err := os.Remove(filepath.Join(r.dir, "main.txt")); err != nil {
		t.Fatal(err)
	}
	r.commit("ada", "Merge side, with edits\n", "")
	evil := strings.TrimSpace(r.git("rev-parse", "HEAD"))

	// A clean merge of disjoint work: its combined diff is empty.
	r.git("checkout", "-q", "-b", "clean")
	r.write("clean.txt", "clean\n")
	r.commit("alan", "Clean side\n", "")
	r.git("checkout", "-q", "main")
	r.write("other.txt", "other\n")
	r.commit("ada", "Other\n", "")
	r.merge("--no-ff", "-m", "Clean merge", "clean")
	r.day++

	// An octopus with an edit of its own.
	for _, arm := range [][2]string{{"o1", "a.txt"}, {"o2", "side.txt"}} {
		b, edit := arm[0], arm[1]
		r.git("checkout", "-q", "-b", b, "main")
		r.write(b+".txt", b+"\n")
		r.write(edit, "edited on "+b+"\n")
		r.commit("alan", "Octopus arm "+b+"\n", "")
		r.git("checkout", "-q", "main")
	}
	r.merge("--no-ff", "--no-commit", "-s", "octopus", "o1", "o2")
	r.write("octo.txt", "octo\n")
	r.commit("ada", "Octopus\n", "")

	gitShows(t, r, "MM\ta.txt", "show", "--name-status", "--format=", evil)
	gitShows(t, r, "AA\tevil.txt", "show", "--name-status", "--format=", evil)
	gitShows(t, r, "AAA\tocto.txt", "show", "--name-status", "--format=", "HEAD")
	gitShows(t, r, `"sp ace \303\251.txt"`, "show", "--name-status", "--format=", evil)
	gitShows(t, r, "-\t-\tbin.dat", "show", "--numstat", "--format=", mainWork)
	gitShows(t, r, "R100\tlib/x.go\tpkg/x.go", "show", "--name-status", "--format=", "side")

	for _, sha := range strings.Fields(r.git("rev-list", "--all")) {
		showDiffs(t, r, sha)
	}
	r.git("config", "core.quotePath", "false")
	showDiffs(t, r, evil)
	r.git("config", "diff.renames", "false")
	showDiffs(t, r, "side")
	showDiffs(t, r, evil)
}

func TestQuotedPathsMatchGit(t *testing.T) {
	r := newRepo(t)
	r.write(".beads/issues.jsonl", beadsLine("q-1", "open"))
	r.write("plain.txt", "x\n")
	r.commit("ada", "Root\n", "")
	r.write("with space.txt", "x\n")
	r.write("tab\there.txt", "x\n")
	r.write(`quote"d.txt`, "x\n")
	r.write("naïve/café.go", "package café\n")
	r.commit("ada", "Awkward names\n", "")
	r.mv("naïve/café.go", "naïve/cafe.go")
	r.mv("with space.txt", "dir/with space.txt")
	r.commit("ada", "Rename awkward names\n", "")

	bvLogs(t, r, ".beads/issues.jsonl")

	r.git("config", "core.quotePath", "false")
	bvLogs(t, r, ".beads/issues.jsonl")
}

func TestRefusesWhatItDoesNotEmulate(t *testing.T) {
	r := newRepo(t)
	r.write("a.txt", "a\n")
	r.commit("ada", "Root\n", "")

	for _, args := range [][]string{
		{"status"},
		{"log", "--oneline"},
		{"log", "--format=%H", "--grep=x"},
		{"log", "--format=%h"},
		{"log", "--format=%H", "--", "a.txt"},
		{"log", "--format=%H", "--since=yesterday"},
		{"log", "--raw", "--format=%H"},
		{"-c", "diff.renames=false", "log", "--format=%H"},
		// show's diff only under the empty format, and only these two.
		{"show", "--name-status", "--format=%H", "HEAD"},
		{"show", "--name-status", "HEAD"},
		{"show", "--name-only", "--format=", "HEAD"},
		{"show", "-s", "--name-status", "--format=%H", "HEAD"},
		{"show", "--format=", "HEAD"},
	} {
		var out bytes.Buffer
		err := Run(context.Background(), r.dir, args, nil, &out)
		exit, ok := err.(*ExitError)
		if !ok || exit.Code != 129 || !strings.Contains(exit.Stderr, "unsupported") {
			t.Errorf("git %q: want an unsupported refusal, got %v", args, err)
		}
		if out.Len() != 0 {
			t.Errorf("git %q: wrote %q before refusing", args, out.String())
		}
	}
}

func TestOutsideARepositoryFailsAsGitDoes(t *testing.T) {
	var out bytes.Buffer
	err := Run(context.Background(), t.TempDir(), []string{"rev-parse", "HEAD"}, nil, &out)
	if exit, ok := err.(*ExitError); !ok || exit.Code != 128 {
		t.Fatalf("want git's fatal exit, got %v", err)
	}
}

func TestLineCounts(t *testing.T) {
	cases := []struct {
		old, new       string
		added, deleted int
	}{
		{"", "a\nb\n", 2, 0},
		{"a\nb\n", "", 0, 2},
		{"a\nb\nc\n", "a\nc\n", 0, 1},
		{"a\nb\nc\n", "a\nB\nc\nd\n", 2, 1},
		{"a", "a\n", 1, 1},
		{"x\ny\nz\n", "z\ny\nx\n", 2, 2},
	}
	for _, c := range cases {
		added, deleted := lineCounts([]byte(c.old), []byte(c.new))
		if added != c.added || deleted != c.deleted {
			t.Errorf("lineCounts(%q, %q) = %d, %d; want %d, %d",
				c.old, c.new, added, deleted, c.added, c.deleted)
		}
	}
}

// git's numstat is not a minimal diff's: xdiff discards unmatched and
// recurring lines before it searches and cuts an expensive search short. Each
// pair here is diffed by git and by lineCounts, from a few lines to files big
// and different enough to reach the heuristic and the cost limit, with lines
// drawn from a small vocabulary so that many recur.
func TestLineCountsMatchGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	dir := t.TempDir()
	rng := rand.New(rand.NewSource(27))
	line := func(vocabulary int) string {
		if rng.Intn(10) == 0 {
			return "\n"
		}
		return fmt.Sprintf("line %d\n", rng.Intn(vocabulary))
	}
	for n := 0; n < 120; n++ {
		size := []int{3, 20, 200, 1500, 4000}[n%5]
		vocabulary := []int{4, 30, 1000}[n%3]
		var a []string
		for i := 0; i < size; i++ {
			a = append(a, line(vocabulary))
		}
		b := append([]string(nil), a...)
		edits := 1 + rng.Intn(size/2+1)
		if n%7 == 0 {
			edits = size * 2
		}
		for e := 0; e < edits; e++ {
			at := 0
			if len(b) > 0 {
				at = rng.Intn(len(b))
			}
			switch rng.Intn(3) {
			case 0:
				b = append(b[:at], append([]string{line(vocabulary)}, b[at:]...)...)
			case 1:
				if len(b) > 0 {
					b = append(b[:at], b[at+1:]...)
				}
			default:
				if len(b) > 0 {
					b[at] = line(vocabulary)
				}
			}
		}
		oldText, newText := strings.Join(a, ""), strings.Join(b, "")
		if n%4 == 0 {
			newText = strings.TrimSuffix(newText, "\n")
		}
		oldPath, newPath := filepath.Join(dir, "a"), filepath.Join(dir, "b")
		if err := os.WriteFile(oldPath, []byte(oldText), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(newPath, []byte(newText), 0o644); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command("git", "diff", "--no-index", "--numstat", oldPath, newPath)
		cmd.Env = gitEnv()
		out, _ := cmd.Output()
		var wantAdded, wantDeleted int
		if len(out) > 0 {
			if _, err := fmt.Sscanf(string(out), "%d\t%d", &wantAdded, &wantDeleted); err != nil {
				t.Fatalf("case %d: reading %q: %v", n, out, err)
			}
		}
		added, deleted := lineCounts([]byte(oldText), []byte(newText))
		if added != wantAdded || deleted != wantDeleted {
			t.Errorf("case %d (%d lines, vocabulary %d, %d edits): %d+ %d-, git says %d+ %d-",
				n, size, vocabulary, edits, added, deleted, wantAdded, wantDeleted)
		}
	}
}
