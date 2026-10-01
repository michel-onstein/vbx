package engine

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/correlation"
)

// staleBeadsRepo builds a repository whose beads are long untouched, with one
// recent commit that names a bead in its message but touches no bead record.
//
// That commit is the divergence: vbx correlates it explicitly, bv never sees
// it, so without narrowing the bead looks freshly worked to triage and stale
// to bv.
func staleBeadsRepo(t *testing.T) string {
	t.Helper()
	b := newRepo(t)

	b.write(".beads/issues.jsonl",
		bead("proj-1", "Rewrite the loader", "open")+"\n"+
			bead("proj-2", "Polish the docs", "open")+"\n")
	b.commit("Add initial beads", "ada")

	// Recent, code-only, and names proj-1. The clock is set relative to now so
	// the commit falls inside the 14-day staleness threshold whenever the test
	// runs, while the bead records above stay in the distant past.
	b.when = time.Now().Add(-2 * time.Hour)
	b.write("src/loader.go", "package src\n\nfunc Load() error { return nil }\n")
	b.commit("Closes proj-1: loader returns an error", "ada")

	return b.dir
}

type triageStaleness struct {
	ProjectHealth struct {
		Staleness *struct {
			StaleCount     int    `json:"stale_count"`
			StalestIssueID string `json:"stalest_issue_id"`
		} `json:"staleness"`
	} `json:"project_health"`
}

// A commit that only mentions a bead must not make it look freshly worked.
//
// Verified against bv v0.20.0 on an equivalent repository: bv reported
// stale_count 3 where vbx reported 2, because vbx credited the explicit-only
// commit as activity. Staleness is 10 % of the triage score, so this moves the
// ranking, not just one field.
func TestTriageStalenessIgnoresExplicitOnlyCommits(t *testing.T) {
	s, err := Open(OpenConfig{Path: staleBeadsRepo(t), SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	out := call[triageStaleness](t, s, "triage", nil)
	if out.ProjectHealth.Staleness == nil {
		t.Fatal("no staleness reported; both beads are months old")
	}
	if got := out.ProjectHealth.Staleness.StaleCount; got != 2 {
		t.Errorf("stale_count is %d, want 2: a commit that merely names proj-1 "+
			"is not activity to bv, so proj-1 must still count as stale", got)
	}
}

// The History view keeps every correlation triage drops.
func TestTriageNarrowingLeavesTheCachedReportIntact(t *testing.T) {
	s, err := Open(OpenConfig{Path: staleBeadsRepo(t), SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	if _, err := s.triage(); err != nil {
		t.Fatalf("triage: %v", err)
	}

	result, err := s.correlationHistory(triageHistoryLimit, false)
	if err != nil {
		t.Fatalf("correlationHistory: %v", err)
	}
	history, ok := result.report.Histories["proj-1"]
	if !ok {
		t.Fatal("proj-1 missing from the report")
	}

	// The explicit-only commit is the History view's whole point: bv's own
	// patterns require a numeric suffix and miss every br-minted id.
	var explicit int
	for _, commit := range history.Commits {
		if commit.Method == correlation.MethodExplicitID {
			explicit++
		}
	}
	if explicit == 0 {
		t.Error("triage narrowing stripped explicit correlations from the shared report")
	}
}

// The narrowing keeps exactly the commits bv derives from the bead's events.
func TestHistoryForTriageKeepsOnlyEventCommits(t *testing.T) {
	report := &correlation.HistoryReport{
		Histories: map[string]correlation.BeadHistory{
			"proj-1": {
				BeadID: "proj-1",
				Events: []correlation.BeadEvent{{BeadID: "proj-1", CommitSHA: "aaa"}},
				Commits: []correlation.CorrelatedCommit{
					{SHA: "aaa", Method: correlation.MethodCoCommitted},
					{SHA: "bbb", Method: correlation.MethodExplicitID},
				},
			},
		},
	}

	narrowed := historyForTriage(report)
	kept := narrowed.Histories["proj-1"].Commits
	if len(kept) != 1 || kept[0].SHA != "aaa" {
		t.Errorf("kept %+v, want only the commit that also produced an event", kept)
	}

	// Selecting by method label rather than by event SHA would be wrong: a
	// commit that both names a bead and edits its record is explicit here and
	// a co-commit to bv, so it has to survive.
	if original := report.Histories["proj-1"].Commits; len(original) != 2 {
		t.Errorf("narrowing mutated the shared report: %+v", original)
	}
}

func TestHistoryForTriageHandlesNoReport(t *testing.T) {
	// Not being in a git repository is the commonest case, and triage still
	// has to answer.
	if historyForTriage(nil) != nil {
		t.Error("a nil report must narrow to nil")
	}
}

// triageWithStatus is triage's staleness plus the status that says whether the
// history signal behind it was available.
type triageWithStatus struct {
	Meta struct {
		HistoryStatus string `json:"history_status"`
	} `json:"meta"`
	triageStaleness
}

// writeUntracked puts a file on disk without staging it.
func writeUntracked(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// staleBeads is two open beads last updated long before any test runs.
var staleBeads = bead("proj-1", "Rewrite the loader", "open") + "\n" +
	bead("proj-2", "Polish the docs", "open") + "\n"

func triageOf(t *testing.T, dir string) triageWithStatus {
	t.Helper()
	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return call[triageWithStatus](t, s, "triage", nil)
}

// When triage cannot use git history, staleness is absent — not computed from
// updated_at against an empty report.
//
// vbx-8u3: Fixtures/sprints, uncommitted inside the vbx repository, made vbx
// report spr-12 as 28 days stale while bv 0.25.2 reported no staleness at all.
// bv leaves the history nil whenever the workspace directory is not itself a
// checkout, and under a pinned clock; vbx used to walk up to the enclosing
// repository, find no events, and let ComputeStaleness fall back to
// updated_at. Each case below was checked against bv 0.25.2.
func TestTriageStalenessIsAbsentWithoutUsableHistory(t *testing.T) {
	t.Run("workspace nested in a repository, beads file untracked", func(t *testing.T) {
		t.Setenv("SOURCE_DATE_EPOCH", "")
		b := newRepo(t)
		b.write("README.md", "outer project\n")
		b.commit("Outer project", "ada")
		workspace := filepath.Join(b.dir, "fixtures", "ws")
		writeUntracked(t, filepath.Join(workspace, ".beads", "issues.jsonl"), staleBeads)

		out := triageOf(t, workspace)
		if out.ProjectHealth.Staleness != nil {
			t.Errorf("staleness %+v reported; bv reports none for a workspace "+
				"that is not itself a checkout", *out.ProjectHealth.Staleness)
		}
		if out.Meta.HistoryStatus != "error" {
			t.Errorf("history status %q, want error", out.Meta.HistoryStatus)
		}
	})

	t.Run("workspace nested in a repository, beads file committed", func(t *testing.T) {
		t.Setenv("SOURCE_DATE_EPOCH", "")
		b := newRepo(t)
		b.write("fixtures/ws/.beads/issues.jsonl", staleBeads)
		b.commit("Add nested beads", "ada")

		out := triageOf(t, filepath.Join(b.dir, "fixtures", "ws"))
		if out.ProjectHealth.Staleness != nil {
			t.Errorf("staleness %+v reported; bv never walks a repository "+
				"above the workspace", *out.ProjectHealth.Staleness)
		}
		if out.Meta.HistoryStatus != "error" {
			t.Errorf("history status %q, want error", out.Meta.HistoryStatus)
		}
	})

	t.Run("not a repository at all", func(t *testing.T) {
		t.Setenv("SOURCE_DATE_EPOCH", "")
		dir := t.TempDir()
		writeUntracked(t, filepath.Join(dir, ".beads", "issues.jsonl"), staleBeads)

		out := triageOf(t, dir)
		if out.ProjectHealth.Staleness != nil {
			t.Errorf("staleness %+v reported outside any repository",
				*out.ProjectHealth.Staleness)
		}
		if out.Meta.HistoryStatus != "error" {
			t.Errorf("history status %q, want error", out.Meta.HistoryStatus)
		}
	})

	t.Run("clock pinned by SOURCE_DATE_EPOCH", func(t *testing.T) {
		t.Setenv("SOURCE_DATE_EPOCH", "1788000000")
		b := newRepo(t)
		b.write(".beads/issues.jsonl", staleBeads)
		b.commit("Add beads", "ada")

		out := triageOf(t, b.dir)
		if out.ProjectHealth.Staleness != nil {
			t.Errorf("staleness %+v reported under a pinned clock; bv skips "+
				"the history walk there", *out.ProjectHealth.Staleness)
		}
		if out.Meta.HistoryStatus != "skipped" {
			t.Errorf("history status %q, want skipped", out.Meta.HistoryStatus)
		}
	})
}

// The other side of the line: at a repository's root the walk runs even when
// the beads file was never committed, and bv then *does* fall back to
// updated_at. Both report the two beads stale, so this must keep working.
func TestTriageStalenessFallsBackToUpdatedAtAtARepositoryRoot(t *testing.T) {
	t.Setenv("SOURCE_DATE_EPOCH", "")
	b := newRepo(t)
	b.write("README.md", "project\n")
	b.commit("Project", "ada")
	writeUntracked(t, filepath.Join(b.dir, ".beads", "issues.jsonl"), staleBeads)

	out := triageOf(t, b.dir)
	if out.Meta.HistoryStatus != "ok" {
		t.Fatalf("history status %q, want ok", out.Meta.HistoryStatus)
	}
	if out.ProjectHealth.Staleness == nil || out.ProjectHealth.Staleness.StaleCount != 2 {
		t.Errorf("staleness %+v, want both beads stale from updated_at",
			out.ProjectHealth.Staleness)
	}
}
