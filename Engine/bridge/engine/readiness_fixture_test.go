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
// fixture at readinessClock, which is parity-check.py's PINNED_CLOCK. Where
// vbx disagrees today the test asserts the disagreement, by name, rather than
// skipping: vbx-hjz aligns vbx with bv's readiness model, and these are the
// tests it flips. A failure here that reads "vbx now agrees" is that bead
// landing, not a regression.

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

func withIDs(base []string, add ...string) []string {
	return sortedIDs(append(slices.Clone(base), add...))
}

func withoutIDs(base []string, drop ...string) []string {
	var out []string
	for _, id := range base {
		if !slices.Contains(drop, id) {
			out = append(out, id)
		}
	}
	return sortedIDs(out)
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
	issues, _, _ := s.snapshot()
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

// TestReadinessFixtureRecipesDisagreeWithBv records how vbx's recipe filter
// (filterByRecipe, a copy outside bv's analysis package) differs from bv
// 0.25.2. It counts only direct blocking edges to an existing open bead, so it
// misses parent gating (rdy-16, rdy-17), a future defer_until (rdy-5) and a
// missing blocker (rdy-9). vbx-hjz replaces it with bv's readiness model.
func TestReadinessFixtureRecipesDisagreeWithBv(t *testing.T) {
	s := openReadiness(t, readinessFixturePath(t))

	vbxActionable := withIDs(bvReady, "rdy-16", "rdy-17", "rdy-5", "rdy-9")
	if got := recipeIDs(t, s, "actionable"); !slices.Equal(got, vbxActionable) {
		if slices.Equal(got, bvReady) {
			t.Fatalf("the actionable recipe now agrees with bv 0.25.2 (vbx-hjz?): assert bvReady here")
		}
		t.Errorf("actionable recipe = %v, want today's %v (bv 0.25.2: %v)", got, vbxActionable, bvReady)
	}

	vbxBlocked := withoutIDs(bvBlocked, "rdy-16", "rdy-17", "rdy-9")
	if got := recipeIDs(t, s, "blocked"); !slices.Equal(got, vbxBlocked) {
		if slices.Equal(got, bvBlocked) {
			t.Fatalf("the blocked recipe now agrees with bv 0.25.2 (vbx-hjz?): assert bvBlocked here")
		}
		t.Errorf("blocked recipe = %v, want today's %v (bv 0.25.2: %v)", got, vbxBlocked, bvBlocked)
	}
}

// TestReadinessFixtureSQLiteLoaderGaps runs the same beads through vbx's own
// SQLite loader, which bv's cannot replace because it is internal. Two gaps
// show, both vbx-hjz's: defer_until is not read, so rdy-5 reads as ready; and
// rows with deleted_at are dropped, so rdy-10's tombstone vanishes and its
// dependent rdy-11 waits on a blocker that is now missing — withheld
// indefinitely, where bv counts the tombstone as resolved.
func TestReadinessFixtureSQLiteLoaderGaps(t *testing.T) {
	dir := t.TempDir()
	writeSQLiteFromJSONL(t, filepath.Join(readinessFixturePath(t), ".beads", "issues.jsonl"),
		filepath.Join(dir, ".beads", "beads.db"))
	s := openReadiness(t, dir)

	issues, _, _ := s.snapshot()
	byID := map[string]model.Issue{}
	for _, issue := range issues {
		byID[issue.ID] = issue
	}
	if byID["rdy-2"].Status != "triage" {
		t.Errorf("custom status lost through SQLite: %q", byID["rdy-2"].Status)
	}

	if _, tombstoneLoaded := byID["rdy-10"]; tombstoneLoaded {
		t.Error("rdy-10 (tombstone) loaded from SQLite; vbx-hjz fixes this — update the assertion")
	}
	if byID["rdy-5"].DeferUntil != nil {
		t.Error("rdy-5 defer_until read from SQLite; vbx-hjz fixes this — update the assertion")
	}

	vbxReady := withIDs(withoutIDs(bvReady, "rdy-11"), "rdy-5")
	if got := actionableIDs(t, s); !slices.Equal(got, vbxReady) {
		t.Errorf("SQLite actionable = %v, want today's %v (bv 0.25.2: %v)", got, vbxReady, bvReady)
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
