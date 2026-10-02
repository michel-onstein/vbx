package correlation

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	bv "github.com/Dicklesworthstone/beads_viewer/pkg/correlation"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/qjam/vbx/engine/objgit"
)

// The two proofs ADR-027 rests on, run on repositories built by real git:
//
//  1. Every git command line this package issues, answered by objgit, is
//     byte-identical to git's own answer (recordingRunner).
//  2. The reports this package builds equal the reports bv's own
//     correlation package builds by spawning git on the same repository.
//
// Tests may spawn git; the package never does.

// recordingRunner answers through objgit and checks each answer against real
// git, failing the test on the first difference.
type recordingRunner struct {
	t    *testing.T
	mu   sync.Mutex
	seen map[string]int
}

func (rr *recordingRunner) run(ctx context.Context, dir string, args []string, stdin io.Reader, stdout io.Writer) error {
	var in bytes.Buffer
	if stdin != nil {
		stdin = io.TeeReader(stdin, &in)
	}
	var out bytes.Buffer
	err := objgit.Run(ctx, dir, args, stdin, io.MultiWriter(stdout, &out))

	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Stdin = bytes.NewReader(in.Bytes())
	want, gitErr := cmd.Output()
	if (err != nil) != (gitErr != nil) {
		rr.t.Errorf("git %q: git error %v, objgit error %v", args, gitErr, err)
	} else if err == nil && !bytes.Equal(want, out.Bytes()) {
		rr.t.Errorf("git %q differs\n--- git\n%q\n--- objgit\n%q", args, want, out.Bytes())
	}
	rr.mu.Lock()
	rr.seen[commandShape(args)]++
	rr.mu.Unlock()
	return err
}

// commandShape names an invocation by its subcommand and flags, for the
// coverage assertion.
func commandShape(args []string) string {
	for len(args) >= 2 && args[0] == "-c" {
		args = args[2:]
	}
	if len(args) == 0 {
		return ""
	}
	shape := []string{args[0]}
	for _, a := range args[1:] {
		if a == "--" {
			break
		}
		if strings.HasPrefix(a, "-") && !strings.HasPrefix(a, "--format=") &&
			!strings.HasPrefix(a, "--since=") && !strings.HasPrefix(a, "--until=") &&
			!strings.HasPrefix(a, "-n") {
			shape = append(shape, a)
		}
	}
	return strings.Join(shape, " ")
}

func recordGit(t *testing.T) *recordingRunner {
	rr := &recordingRunner{t: t, seen: map[string]int{}}
	t.Cleanup(SetGitRunner(rr.run))
	return rr
}

// isolate keeps the user's git configuration and bv's caches out of both
// sides.
func isolate(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_SYSTEM", "/dev/null")
	t.Setenv("BV_NO_CACHE", "1")
	t.Setenv("BV_ROBOT", "")
}

// fixtureCommit is one commit of a built repository: the bead statuses it
// sets and the files it writes.
type fixtureCommit struct {
	day     int
	author  int
	message string
	beads   map[string]string
	files   map[string]int
	remove  []string
	rename  [2]string
}

var fixtureAuthors = [][2]string{{"Ada Lovelace", "ada@example.com"}, {"Alan Turing", "alan@example.com"}}

// historyFixture is parity-check.py's `history` repository, built the same
// way: the same beads, authors, days and messages.
var historyBeads = []string{"hist-1", "hist-2", "hist-3", "hist-4", "hist-5", "hist-6", "hist-7", "hist-8"}

var historyCommits = []fixtureCommit{
	{1, 0, "Initial import", nil, map[string]int{"README.md": 1, "src/parser.go": 1}, nil, [2]string{}},
	{2, 0, "hist-1: start the parser rewrite", map[string]string{"hist-1": "in_progress"}, map[string]int{"src/parser.go": 2}, nil, [2]string{}},
	{3, 0, "Parse nested blocks (hist-1)", nil, map[string]int{"src/parser.go": 3, "src/ast.go": 1}, nil, [2]string{}},
	{4, 0, "Close hist-1", map[string]string{"hist-1": "closed"}, map[string]int{"src/parser.go": 4}, nil, [2]string{}},
	{5, 1, "hist-2 lexer recovery", map[string]string{"hist-2": "in_progress"}, map[string]int{"src/lexer.go": 1, "src/parser.go": 5}, nil, [2]string{}},
	{6, 1, "tweak lexer constants", nil, map[string]int{"src/lexer.go": 2}, nil, [2]string{}},
	{7, 0, "hist-3: results view", map[string]string{"hist-3": "in_progress"}, map[string]int{"ui/view.swift": 1, "ui/model.swift": 1}, nil, [2]string{}},
	{8, 1, "close hist-2", map[string]string{"hist-2": "closed"}, map[string]int{"src/lexer.go": 3}, nil, [2]string{}},
	{9, 1, "docs: update the guide", map[string]string{"hist-4": "closed"}, map[string]int{"README.md": 2, "docs/guide.md": 1}, nil, [2]string{}},
	{10, 0, "cache: add an LRU (hist-5)", map[string]string{"hist-5": "in_progress"}, map[string]int{"src/cache.go": 1, "src/parser.go": 6}, nil, [2]string{}},
	{11, 0, "Drop the spike", map[string]string{"hist-8": "tombstone"}, map[string]int{"src/cache.go": 2}, nil, [2]string{}},
	{12, 1, "Fix view refresh for hist-3", nil, map[string]int{"ui/view.swift": 2, "ui/model.swift": 2}, nil, [2]string{}},
	{13, 1, "Plan the build split", nil, map[string]int{"scripts/build.sh": 1}, nil, [2]string{}},
}

// buildRepo writes the commits into a new repository and returns its
// directory and the beads as they stand at HEAD.
func buildRepo(t *testing.T, beadIDs []string, commits []fixtureCommit, beadsFile string) (string, []model.Issue) {
	t.Helper()
	dir := t.TempDir()
	git := func(env []string, args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), env...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	git(nil, "init", "-q", "-b", "main")
	statuses := map[string]string{}
	created := map[string]int{}
	var issues []model.Issue
	for _, c := range commits {
		for id, status := range c.beads {
			statuses[id] = status
		}
		if c.rename[0] != "" {
			if err := os.MkdirAll(filepath.Join(dir, filepath.Dir(c.rename[1])), 0o755); err != nil {
				t.Fatal(err)
			}
			git(nil, "mv", c.rename[0], c.rename[1])
			beadsFile = c.rename[1]
		}
		var lines []string
		issues = issues[:0]
		for _, id := range beadIDs {
			if _, ok := created[id]; !ok {
				created[id] = c.day
			}
			status := statuses[id]
			if status == "" {
				status = "open"
			}
			stamp := fmt.Sprintf("2026-08-%02dT10:00:00Z", created[id])
			rec := map[string]any{"id": id, "title": "Bead " + id, "status": status,
				"issue_type": "task", "priority": 2, "created_at": stamp, "updated_at": stamp}
			raw, _ := json.Marshal(rec)
			lines = append(lines, string(raw))
			issues = append(issues, model.Issue{ID: id, Title: "Bead " + id, Status: model.Status(status)})
		}
		full := filepath.Join(dir, beadsFile)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		for path, version := range c.files {
			p := filepath.Join(dir, path)
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte(fmt.Sprintf("%s version %d\n", path, version)), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		for _, path := range c.remove {
			if err := os.Remove(filepath.Join(dir, path)); err != nil {
				t.Fatal(err)
			}
		}
		git(nil, "add", "-A")
		who := fixtureAuthors[c.author]
		when := fmt.Sprintf("2026-08-%02dT10:00:00Z", c.day)
		git([]string{"GIT_AUTHOR_NAME=" + who[0], "GIT_AUTHOR_EMAIL=" + who[1], "GIT_AUTHOR_DATE=" + when,
			"GIT_COMMITTER_NAME=" + who[0], "GIT_COMMITTER_EMAIL=" + who[1], "GIT_COMMITTER_DATE=" + when},
			"commit", "-q", "--allow-empty", "-m", c.message)
	}
	visible := issues[:0:0]
	for _, issue := range issues {
		if issue.Status != model.StatusTombstone {
			visible = append(visible, issue)
		}
	}
	return dir, visible
}

func beadInfos(issues []model.Issue) ([]BeadInfo, []bv.BeadInfo) {
	ours := make([]BeadInfo, len(issues))
	theirs := make([]bv.BeadInfo, len(issues))
	for i, issue := range issues {
		ours[i] = BeadInfo{ID: issue.ID, Title: issue.Title, Status: string(issue.Status)}
		theirs[i] = bv.BeadInfo{ID: issue.ID, Title: issue.Title, Status: string(issue.Status)}
	}
	return ours, theirs
}

// normalized marshals a report with the values that measure the run rather
// than the history — wall-clock stamps and strategy timings — zeroed.
func normalized(t *testing.T, v any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	delete(m, "generated_at")
	if stats, ok := m["stats"].(map[string]any); ok {
		if runs, ok := stats["strategies"].([]any); ok {
			for _, run := range runs {
				if r, ok := run.(map[string]any); ok {
					delete(r, "duration_ms")
				}
			}
		}
	}
	return m
}

func requireSame(t *testing.T, what string, ours, theirs any) {
	t.Helper()
	a, b := normalized(t, ours), normalized(t, theirs)
	if !reflect.DeepEqual(a, b) {
		x, _ := json.MarshalIndent(a, "", " ")
		y, _ := json.MarshalIndent(b, "", " ")
		t.Fatalf("%s differs from bv's\n--- vbx\n%s\n--- bv\n%s", what, x, y)
	}
}

// compareWithBV runs every report the nine history commands read, both
// ways, on one repository.
func compareWithBV(t *testing.T, dir, beadsPath string, issues []model.Issue, focus string) {
	t.Helper()
	ours, theirs := beadInfos(issues)
	now := time.Date(2026, 8, 29, 10, 40, 0, 0, time.UTC)
	since := time.Date(2026, 8, 5, 0, 0, 0, 0, time.UTC)
	for _, opts := range []CorrelatorOptions{
		{Limit: 500},
		{Limit: 4},
		{Limit: 500, Since: &since},
		{Limit: 500, BeadID: focus},
		{Limit: 500, CausalityBeadID: focus},
	} {
		bvOpts := bv.CorrelatorOptions{Limit: opts.Limit, Since: opts.Since, BeadID: opts.BeadID,
			CausalityBeadID: opts.CausalityBeadID}
		name := fmt.Sprintf("%+v", bvOpts)

		report, err := NewCorrelator(dir, beadsPath).GenerateReport(ours, opts)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		want, err := bv.NewCorrelator(dir, beadsPath).GenerateReport(theirs, bvOpts)
		if err != nil {
			t.Fatalf("%s: bv: %v", name, err)
		}
		requireSame(t, "report "+name, report, want)

		// The artifact route vbx uses must assemble the same report.
		c := NewCorrelator(dir, beadsPath)
		art, err := c.ExtractArtifact(CorrelatorOptions{Limit: opts.Limit, Since: opts.Since, BeadID: opts.BeadID})
		if err != nil {
			t.Fatal(err)
		}
		if opts.CausalityBeadID != "" {
			causal, err := c.ExtractCausalHistory(opts.CausalityBeadID, opts)
			if err != nil {
				t.Fatal(err)
			}
			art = art.WithCausalHistory(causal)
		}
		requireSame(t, "assembled report "+name, c.AssembleReport(ours, opts, art), want)

		orphans, err := NewOrphanDetectorAt(report, dir, now).DetectOrphans(ExtractOptions{Limit: opts.Limit})
		if err != nil {
			t.Fatal(err)
		}
		wantOrphans, err := bv.NewOrphanDetectorAt(want, dir, now).DetectOrphans(bv.ExtractOptions{Limit: opts.Limit})
		if err != nil {
			t.Fatal(err)
		}
		requireSame(t, "orphans "+name, orphans, wantOrphans)

		if opts.CausalityBeadID != "" {
			requireSame(t, "causality "+name,
				report.BuildCausalityChainAt(focus, CausalityOptions{IncludeCommits: true}, now),
				want.BuildCausalityChainAt(focus, bv.CausalityOptions{IncludeCommits: true}, now))
		}
	}
}

func TestHistoryFixtureMatchesBV(t *testing.T) {
	isolate(t)
	rr := recordGit(t)
	dir, issues := buildRepo(t, historyBeads, historyCommits, ".beads/issues.jsonl")
	compareWithBV(t, dir, filepath.Join(dir, ".beads", "issues.jsonl"), issues, "hist-1")

	// Every kind of command line the correlator issues was exercised, so
	// none of them escaped the byte comparison.
	for _, shape := range []string{
		"log --no-merges --name-only",
		"log --no-walk=unsorted --name-status",
		"log --no-walk=unsorted --numstat",
		"log --raw --no-abbrev --follow",
		"log --first-parent --diff-merges=first-parent --raw --no-abbrev --follow",
		"cat-file --batch",
	} {
		if rr.seen[shape] == 0 {
			t.Errorf("no %q invocation was compared; seen: %v", shape, rr.seen)
		}
	}
}

func TestRenamedBeadsFileMatchesBV(t *testing.T) {
	isolate(t)
	recordGit(t)
	ids := []string{"r-1", "r-2", "r-3", "r-4", "r-5", "r-6", "r-7", "r-8"}
	commits := []fixtureCommit{
		{1, 0, "Initial import", nil, map[string]int{"main.go": 1}, nil, [2]string{}},
		{2, 0, "r-1: start", map[string]string{"r-1": "in_progress"}, map[string]int{"main.go": 2}, nil, [2]string{}},
		{3, 1, "Move the beads file", map[string]string{"r-2": "in_progress"}, map[string]int{"lib/a.go": 1}, nil,
			[2]string{".beads/beads.jsonl", ".beads/issues.jsonl"}},
		{4, 1, "Rename lib (r-2)", nil, nil, nil, [2]string{"lib/a.go", "pkg/a.go"}},
		{5, 0, "Close r-1 and r-2", map[string]string{"r-1": "closed", "r-2": "closed"}, map[string]int{"pkg/a.go": 2}, []string{"main.go"}, [2]string{}},
		{6, 1, "Unrelated work", nil, map[string]int{"vendor/x.go": 1, "node_modules/y.js": 1, "docs/z.md": 1}, nil, [2]string{}},
	}
	dir, issues := buildRepo(t, ids, commits, ".beads/beads.jsonl")
	compareWithBV(t, dir, filepath.Join(dir, ".beads", "issues.jsonl"), issues, "r-1")
}
