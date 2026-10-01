package engine

import (
	"bufio"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	_ "modernc.org/sqlite"
)

// Fixtures/readiness holds the readiness and blocking cases bv 0.25 changed
// and the demo fixture does not reach: a custom status, waits-for and
// conditional-blocks edges, a future and a past defer_until, a blocker no
// bead in the workspace has, parent-child gating, an epic with open children,
// blocked and deferred statuses, and a tombstoned blocker. Each bead's
// description says what it is for.
//
// The expectations marked "bv 0.25.2" were read from bv 0.25.2 itself over this
// fixture at readinessClock, which is parity-check.py's PINNED_CLOCK. vbx-h22
// first pinned where vbx disagreed; vbx-hjz aligned recipes, the SQLite loader
// and tombstone handling with bv's readiness model, so every assertion here is
// now agreement.

// readinessClock is 2026-08-29T10:40:00Z, after every date in the fixture and
// before rdy-5's defer_until.
var readinessClock = time.Unix(1788000000, 0).UTC()

// bvReady is the set bv 0.25.2 reports as ready at readinessClock: its
// --robot-plan items, and its triage recommendations under --recipe
// actionable. Only open and in_progress beads, no future deferral, every
// blocking edge resolved (a tombstone resolves one; a missing target does not),
// and every ancestor's dependencies satisfied.
var bvReady = []string{
	"rdy-1", "rdy-11", "rdy-12", "rdy-13", "rdy-15", "rdy-19", "rdy-20", "rdy-21", "rdy-6",
}

// bvBlocked is bv 0.25.2's triage under --recipe blocked: rdy-14's own
// blocker, the subtree it gates, both newer blocking edge types, and the
// missing blocker.
var bvBlocked = []string{"rdy-14", "rdy-16", "rdy-17", "rdy-7", "rdy-8", "rdy-9"}

func readinessFixturePath(t *testing.T) string {
	t.Helper()
	// Engine/bridge/engine -> repository root.
	path, err := filepath.Abs(filepath.Join("..", "..", "..", "Fixtures", "readiness"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(path, ".beads", "issues.jsonl")); err != nil {
		t.Fatalf("readiness fixture missing: %v", err)
	}
	return path
}

func openReadiness(t *testing.T, path string) *Session {
	t.Helper()
	setClock(t, readinessClock)
	s, err := Open(OpenConfig{Path: path, SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open(%s): %v", path, err)
	}
	t.Cleanup(s.Close)
	return s
}

func sortedIDs(ids []string) []string {
	out := slices.Clone(ids)
	slices.Sort(out)
	return out
}

func actionableIDs(t *testing.T, s *Session) []string {
	t.Helper()
	got := call[struct {
		IDs []string `json:"ids"`
	}](t, s, "actionable", nil)
	return sortedIDs(got.IDs)
}

func recipeIDs(t *testing.T, s *Session, name string) []string {
	t.Helper()
	got := call[recipeApplyShape](t, s, "recipe_apply", map[string]any{"name": name})
	return sortedIDs(got.IssueIDs)
}

// TestReadinessFixtureLoadsEveryRecord: nothing in the fixture is dropped or
// normalised away by the JSONL loader — not the custom status (v0.20.0's
// loader dropped it silently), not the tombstone, not either newer edge type,
// and not the dangling reference.
func TestReadinessFixtureLoadsEveryRecord(t *testing.T) {
	s := openReadiness(t, readinessFixturePath(t))
	issues := s.recordSet()
	if len(issues) != 21 {
		t.Fatalf("loaded %d beads, want all 21", len(issues))
	}
	byID := map[string]model.Issue{}
	for _, issue := range issues {
		byID[issue.ID] = issue
	}

	for id, status := range map[string]model.Status{
		"rdy-2": "triage", "rdy-3": model.StatusBlocked, "rdy-4": model.StatusDeferred,
		"rdy-10": model.StatusTombstone, "rdy-18": model.StatusClosed,
		"rdy-20": model.StatusInProgress,
	} {
		if got := byID[id].Status; got != status {
			t.Errorf("%s status = %q, want %q", id, got, status)
		}
	}
	for id, at := range map[string]string{"rdy-5": "2099-01-01T00:00:00Z", "rdy-6": "2026-06-01T00:00:00Z"} {
		want, _ := time.Parse(time.RFC3339, at)
		if got := byID[id].DeferUntil; got == nil || !got.Equal(want) {
			t.Errorf("%s defer_until = %v, want %s", id, got, at)
		}
	}
	for id, edge := range map[string]string{
		"rdy-7":  "rdy-1/waits-for",
		"rdy-8":  "rdy-1/conditional-blocks",
		"rdy-9":  "external:upstream:rdy-404/blocks",
		"rdy-11": "rdy-10/blocks",
		"rdy-17": "rdy-16/parent-child",
	} {
		deps := byID[id].Dependencies
		if len(deps) != 1 || fmt.Sprintf("%s/%s", deps[0].DependsOnID, deps[0].Type) != edge {
			t.Errorf("%s dependencies = %v, want one %s", id, deps, edge)
		}
	}
}

// TestReadinessFixtureActionableMatchesBv: the analyzer's actionable set is
// bv's own (the engine's analysis package is bv 0.25.2), which is what makes
// it the reference for the copies vbx keeps outside that package.
func TestReadinessFixtureActionableMatchesBv(t *testing.T) {
	s := openReadiness(t, readinessFixturePath(t))
	if got := actionableIDs(t, s); !slices.Equal(got, bvReady) {
		t.Errorf("actionable = %v\nbv 0.25.2 = %v", got, bvReady)
	}
}

// TestReadinessFixtureTombstoneIsResolvedButNotAnalysed is bv 0.25.2's split:
// the tombstone rdy-10 is out of the analysis set (bv's triage counts 20
// beads, not 21) but still resolves rdy-11's blocking edge, and the record
// itself is still in the issues payload, because decoding never drops one.
func TestReadinessFixtureTombstoneIsResolvedButNotAnalysed(t *testing.T) {
	s := openReadiness(t, readinessFixturePath(t))

	issues, _, _ := s.snapshot()
	if len(issues) != 20 || slices.ContainsFunc(issues, func(i model.Issue) bool { return i.ID == "rdy-10" }) {
		t.Errorf("analysis set has %d beads (want bv's 20, without rdy-10)", len(issues))
	}
	payload := call[struct {
		Issues []model.Issue `json:"issues"`
	}](t, s, "issues", nil)
	if len(payload.Issues) != 21 {
		t.Errorf("issues payload has %d records, want all 21, the tombstone included", len(payload.Issues))
	}
	if !s.readinessIndex().Ready("rdy-11", readinessClock) {
		t.Error("rdy-11 is withheld; its only blocker is the tombstone rdy-10, which bv counts as resolved")
	}

	triage := call[struct {
		Meta struct {
			IssueCount int `json:"issue_count"`
		} `json:"meta"`
	}](t, s, "triage", nil)
	if triage.Meta.IssueCount != 20 {
		t.Errorf("triage counts %d beads, bv 0.25.2 counts 20", triage.Meta.IssueCount)
	}
}

// TestReadinessFixtureRecipesMatchBv: recipes run through bv's recipe.Apply
// over the full-source readiness authority, so `actionable` withholds a
// blocked parent's subtree (rdy-16, rdy-17), a future defer_until (rdy-5) and
// a missing blocker (rdy-9) — all of which vbx's old copy of the filter let
// through — and `blocked` reports them.
func TestReadinessFixtureRecipesMatchBv(t *testing.T) {
	s := openReadiness(t, readinessFixturePath(t))

	if got := recipeIDs(t, s, "actionable"); !slices.Equal(got, bvReady) {
		t.Errorf("actionable recipe = %v\nbv 0.25.2 = %v", got, bvReady)
	}
	if got := recipeIDs(t, s, "blocked"); !slices.Equal(got, bvBlocked) {
		t.Errorf("blocked recipe = %v\nbv 0.25.2 = %v", got, bvBlocked)
	}
}

// TestReadinessFixtureSQLiteMatchesBv runs the same beads through vbx's own
// SQLite loader, which bv's cannot replace because it is internal. It reads
// defer_until, so rdy-5 is withheld; and it keeps the deleted row, so rdy-10
// is a tombstone that resolves rdy-11's blocker instead of a missing bead
// that withholds it for ever.
func TestReadinessFixtureSQLiteMatchesBv(t *testing.T) {
	dir := t.TempDir()
	writeSQLiteFromJSONL(t, filepath.Join(readinessFixturePath(t), ".beads", "issues.jsonl"),
		filepath.Join(dir, ".beads", "beads.db"))
	s := openReadiness(t, dir)

	byID := map[string]model.Issue{}
	for _, issue := range s.recordSet() {
		byID[issue.ID] = issue
	}
	if byID["rdy-2"].Status != "triage" {
		t.Errorf("custom status lost through SQLite: %q", byID["rdy-2"].Status)
	}
	if got := byID["rdy-10"].Status; got != model.StatusTombstone {
		t.Errorf("rdy-10 through SQLite has status %q, want the tombstone kept", got)
	}
	want, _ := time.Parse(time.RFC3339, "2099-01-01T00:00:00Z")
	if got := byID["rdy-5"].DeferUntil; got == nil || !got.Equal(want) {
		t.Errorf("rdy-5 defer_until through SQLite = %v, want %s", got, want)
	}

	if got := actionableIDs(t, s); !slices.Equal(got, bvReady) {
		t.Errorf("SQLite actionable = %v\nbv 0.25.2 = %v", got, bvReady)
	}
	if got := recipeIDs(t, s, "actionable"); !slices.Equal(got, bvReady) {
		t.Errorf("SQLite actionable recipe = %v\nbv 0.25.2 = %v", got, bvReady)
	}
	if issues, _, _ := s.snapshot(); len(issues) != 20 {
		t.Errorf("SQLite analysis set has %d beads, want bv's 20", len(issues))
	}
}

// brIssueColumns is br's issues table, in br's order — the same list
// parity-check.py's BR_ISSUE_COLUMNS writes, so the Go suite and the parity
// run read the same shape of database.
var brIssueColumns = []string{
	"id", "content_hash", "title", "description", "design", "acceptance_criteria",
	"notes", "status", "priority", "issue_type", "assignee", "owner",
	"estimated_minutes", "created_at", "created_by", "updated_at", "closed_at",
	"close_reason", "closed_by_session", "due_at", "defer_until", "external_ref",
	"source_system", "source_repo", "deleted_at", "deleted_by", "delete_reason",
	"original_type", "compaction_level", "compacted_at", "compacted_at_commit",
	"original_size", "sender", "ephemeral", "pinned", "is_template",
	"source_repo_path", "agent_context", "prerequisites",
}

// writeSQLiteFromJSONL builds a beads.db holding every record in a JSONL
// export, tombstones included, as br stores them.
func writeSQLiteFromJSONL(t *testing.T, jsonl, database string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(database), 0o755); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", "file:"+database)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	var defs []string
	for _, c := range brIssueColumns {
		if strings.HasSuffix(c, "_at") || c == "defer_until" {
			defs = append(defs, c+" DATETIME")
		} else {
			defs = append(defs, c)
		}
	}
	for _, stmt := range []string{
		fmt.Sprintf("CREATE TABLE issues (%s, PRIMARY KEY (id))", strings.Join(defs, ", ")),
		`CREATE TABLE dependencies (issue_id TEXT, depends_on_id TEXT, type TEXT,
			created_at DATETIME, created_by TEXT, metadata TEXT, thread_id TEXT)`,
		`CREATE TABLE labels (issue_id TEXT, label TEXT)`,
		`CREATE TABLE comments (id TEXT, issue_id TEXT, author TEXT, text TEXT, created_at DATETIME)`,
	} {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}

	f, err := os.Open(jsonl)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	placeholders := strings.TrimSuffix(strings.Repeat("?, ", len(brIssueColumns)), ", ")
	insert := fmt.Sprintf("INSERT INTO issues (%s) VALUES (%s)",
		strings.Join(brIssueColumns, ", "), placeholders)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		if strings.TrimSpace(scanner.Text()) == "" {
			continue
		}
		var record map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			t.Fatal(err)
		}
		defaults := map[string]any{
			"description": "", "design": "", "acceptance_criteria": "", "notes": "",
			"source_repo": ".", "ephemeral": 0, "pinned": 0, "is_template": 0, "prerequisites": "",
		}
		values := make([]any, len(brIssueColumns))
		for i, c := range brIssueColumns {
			v, ok := record[c]
			if !ok {
				v = defaults[c]
			}
			values[i] = v
		}
		if _, err := db.Exec(insert, values...); err != nil {
			t.Fatalf("insert %v: %v", record["id"], err)
		}
		id := record["id"]
		if labels, ok := record["labels"].([]any); ok {
			for _, label := range labels {
				if _, err := db.Exec("INSERT INTO labels VALUES (?, ?)", id, label); err != nil {
					t.Fatal(err)
				}
			}
		}
		if deps, ok := record["dependencies"].([]any); ok {
			for _, raw := range deps {
				d := raw.(map[string]any)
				if _, err := db.Exec("INSERT INTO dependencies VALUES (?, ?, ?, ?, ?, '{}', '')",
					id, d["depends_on_id"], d["type"], d["created_at"], d["created_by"]); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
}
