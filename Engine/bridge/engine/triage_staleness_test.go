package engine

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// staleBeadsRepo builds a repository whose beads are long untouched, with one
// recent commit that names a bead in its message but touches no bead record.
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

// A commit naming a bead is activity on it, to triage as to the History view.
//
// bv 0.25.2's triage builds its history with the full correlator — the
// explicit-id and temporal strategies included — so a code commit whose
// message names proj-1 makes proj-1 freshly worked: on this repository it
// reports stale_count 1, proj-2 alone. vbx used to narrow triage's copy of the
// report to co-committed links, written against bv 0.20, whose triage never
// saw explicit links; against 0.25.2 that narrowing reported 2 (BUGS.md,
// 2026-10-02).
func TestTriageStalenessCountsACommitNamingTheBead(t *testing.T) {
	t.Setenv("SOURCE_DATE_EPOCH", "")
	s, err := Open(OpenConfig{Path: staleBeadsRepo(t), SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	out := call[triageStaleness](t, s, "triage", nil)
	if out.ProjectHealth.Staleness == nil {
		t.Fatal("no staleness reported; proj-2 is months old")
	}
	if got := out.ProjectHealth.Staleness.StaleCount; got != 1 {
		t.Errorf("stale_count is %d, want 1: the commit naming proj-1 is activity", got)
	}
	if got := out.ProjectHealth.Staleness.StalestIssueID; got != "proj-2" {
		t.Errorf("stalest is %q, want proj-2", got)
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
