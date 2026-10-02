package engine

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// makeBeadsDB builds a store with the column shape a current beads.db has,
// including the columns vbx does not read, so the projection logic is
// exercised against a realistic schema rather than a minimal one.
func makeBeadsDB(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "beads.db")

	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	stmts := []string{
		`CREATE TABLE issues (
			id TEXT PRIMARY KEY, content_hash TEXT, title TEXT, description TEXT,
			design TEXT, acceptance_criteria TEXT, notes TEXT, status TEXT,
			priority INTEGER, issue_type TEXT, assignee TEXT, owner TEXT,
			estimated_minutes INTEGER, created_at DATETIME, created_by TEXT,
			updated_at DATETIME, closed_at DATETIME, due_at DATETIME,
			defer_until DATETIME, external_ref TEXT, source_repo TEXT,
			deleted_at DATETIME, compaction_level INTEGER, original_size INTEGER)`,
		`CREATE TABLE dependencies (
			issue_id TEXT, depends_on_id TEXT, type TEXT,
			created_at DATETIME, created_by TEXT)`,
		`CREATE TABLE labels (issue_id TEXT, label TEXT)`,
		`CREATE TABLE comments (
			id TEXT, issue_id TEXT, author TEXT, text TEXT, created_at DATETIME)`,

		`INSERT INTO issues (id,title,description,status,priority,issue_type,assignee,
			estimated_minutes,created_at,updated_at,defer_until)
		 VALUES ('s-1','First','desc one','open',1,'task','michel',60,
			'2026-01-01T00:00:00Z','2026-02-01T00:00:00Z','2099-01-01T00:00:00Z')`,
		`INSERT INTO issues (id,title,status,priority,issue_type,created_at,updated_at)
		 VALUES ('s-2','Second','closed',0,'bug',
			'2026-01-02T00:00:00Z','2026-02-02T00:00:00Z')`,
		// A deleted row, as br writes one: status tombstone and deleted_at.
		// It loads — a deleted blocker is a resolved one — and the session
		// keeps it out of analysis.
		`INSERT INTO issues (id,title,status,issue_type,deleted_at)
		 VALUES ('s-gone','Deleted','tombstone','task','2026-03-01T00:00:00Z')`,

		`INSERT INTO dependencies (issue_id,depends_on_id,type)
		 VALUES ('s-1','s-2','blocks')`,
		// A legacy row with no type: must still count as blocking.
		`INSERT INTO dependencies (issue_id,depends_on_id,type) VALUES ('s-1','s-2','')`,
		// A dangling target must not crash the load.
		`INSERT INTO dependencies (issue_id,depends_on_id,type)
		 VALUES ('s-1','s-missing','blocks')`,

		`INSERT INTO labels (issue_id,label) VALUES ('s-1','core')`,
		`INSERT INTO labels (issue_id,label) VALUES ('s-1','infra')`,
		`INSERT INTO comments (id,issue_id,author,text,created_at)
		 VALUES ('c1','s-1','michel','a comment','2026-01-05T00:00:00Z')`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("exec %q: %v", s, err)
		}
	}
	return path
}

func TestLoadSQLite(t *testing.T) {
	path := makeBeadsDB(t, t.TempDir())

	issues, _, _, err := LoadSQLite(path)
	if err != nil {
		t.Fatalf("LoadSQLite: %v", err)
	}

	if len(issues) != 3 {
		t.Fatalf("got %d issues, want 3 (the deleted row is kept, as bv keeps it)", len(issues))
	}

	byID := map[string]int{}
	for i, it := range issues {
		byID[it.ID] = i
	}
	// Regression (vbx-hjz): the loader used to drop rows with deleted_at, so a
	// bead blocked only by a deleted one waited on a missing blocker for ever.
	if gone, ok := byID["s-gone"]; !ok || issues[gone].Status != "tombstone" {
		t.Error("the deleted row was not loaded as a tombstone")
	}

	first := issues[byID["s-1"]]
	if first.Title != "First" || first.Description != "desc one" {
		t.Errorf("text fields wrong: %+v", first)
	}
	if first.Assignee != "michel" {
		t.Errorf("assignee = %q", first.Assignee)
	}
	if first.Priority != 1 {
		t.Errorf("priority = %d, want 1", first.Priority)
	}
	if first.EstimatedMinutes == nil || *first.EstimatedMinutes != 60 {
		t.Errorf("estimated_minutes not read")
	}
	if first.CreatedAt.IsZero() || first.UpdatedAt.IsZero() {
		t.Errorf("timestamps not parsed: %v / %v", first.CreatedAt, first.UpdatedAt)
	}
	// Regression (vbx-hjz): defer_until was not read, so a bead deferred into
	// the future read as ready from beads.db and not from the JSONL.
	if first.DeferUntil == nil || first.DeferUntil.Year() != 2099 {
		t.Errorf("defer_until not read: %v", first.DeferUntil)
	}
	if len(first.Labels) != 2 {
		t.Errorf("labels = %v, want 2", first.Labels)
	}
	if len(first.Comments) != 1 || first.Comments[0].Text != "a comment" {
		t.Errorf("comments not loaded: %+v", first.Comments)
	}
	if len(first.Dependencies) != 3 {
		t.Errorf("dependencies = %d, want 3 (including the dangling one)", len(first.Dependencies))
	}

	// The empty-typed dependency must still block, matching bv's rule.
	blocking := 0
	for _, d := range first.Dependencies {
		if d.Type.IsBlocking() {
			blocking++
		}
	}
	if blocking != 3 {
		t.Errorf("%d blocking deps, want 3 (empty type blocks)", blocking)
	}
}

func TestLoadSQLiteMissingFile(t *testing.T) {
	if _, _, _, err := LoadSQLite(filepath.Join(t.TempDir(), "nope.db")); err == nil {
		t.Error("expected an error for a missing database")
	}
}

func TestSessionOpensSQLiteWorkspace(t *testing.T) {
	// An empty issues.jsonl next to a populated beads.db is the normal shape
	// in bd-managed repos; discovery must not stop at the empty JSONL.
	dir := t.TempDir()
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(beads, "issues.jsonl"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	makeBeadsDB(t, beads)

	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer s.Close()

	raw, err := s.Call("info", nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(raw); !contains(got, `"kind":"sqlite"`) {
		t.Errorf("expected the sqlite source to be chosen, got %s", got)
	}
	// issue_count is every record, the tombstone included; the analysis set
	// leaves it out, as bv's does.
	if got := string(raw); !contains(got, `"issue_count":3`) {
		t.Errorf("expected 3 records, got %s", got)
	}
	if issues, _, _ := s.snapshot(); len(issues) != 2 {
		t.Errorf("analysis set has %d beads, want 2 without the tombstone", len(issues))
	}
}

// TestLoadSQLiteHonoursTheTombstoneColumn: an older schema marks a deleted
// row with a `tombstone` flag rather than its status, and bv reads it.
func TestLoadSQLiteHonoursTheTombstoneColumn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "beads.db")
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`CREATE TABLE issues (id TEXT PRIMARY KEY, title TEXT, status TEXT, tombstone INTEGER)`,
		`INSERT INTO issues VALUES ('t-1','Kept','open',0), ('t-2','Flagged','open',1)`,
	} {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()

	issues, _, _, err := LoadSQLite(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(issues) != 2 || issues[0].Status != "open" || issues[1].Status != "tombstone" {
		t.Errorf("loaded %+v, want t-1 open and t-2 a tombstone", issues)
	}
}

// TestLoadSQLiteOrdersAsBvDoes is the regression test for vbx-dj4: the
// loader sorted by id, so on a beads.db every tie-break downstream (alerts,
// a label's issue list and top issue) came out in a different order from
// bv's. bv's reader orders by updated_at DESC, ties in SQLite's row order,
// and by id only where the schema has no updated_at.
func TestLoadSQLiteOrdersAsBvDoes(t *testing.T) {
	open := func(t *testing.T, stmts ...string) string {
		t.Helper()
		path := filepath.Join(t.TempDir(), "beads.db")
		db, err := sql.Open("sqlite", "file:"+path)
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		for _, stmt := range stmts {
			if _, err := db.Exec(stmt); err != nil {
				t.Fatalf("exec %q: %v", stmt, err)
			}
		}
		return path
	}
	ids := func(t *testing.T, path string) []string {
		t.Helper()
		issues, _, _, err := LoadSQLite(path)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, it := range issues {
			out = append(out, it.ID)
		}
		return out
	}

	t.Run("newest update first, ties in row order", func(t *testing.T) {
		// Inserted so that neither id order nor insertion order is the answer.
		// o-9 and o-10 tie; id order would put o-10 first, bv puts o-9 first.
		path := open(t,
			`CREATE TABLE issues (id TEXT PRIMARY KEY, title TEXT, status TEXT, updated_at DATETIME)`,
			`INSERT INTO issues VALUES ('o-2','Oldest','open','2026-01-01T00:00:00Z')`,
			`INSERT INTO issues VALUES ('o-11','Newest','open','2026-03-01T00:00:00Z')`,
			`INSERT INTO issues VALUES ('o-9','Tied A','open','2026-02-01T00:00:00Z')`,
			`INSERT INTO issues VALUES ('o-10','Tied B','open','2026-02-01T00:00:00Z')`,
		)
		got := ids(t, path)
		want := []string{"o-11", "o-9", "o-10", "o-2"}
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Errorf("order = %v, want %v (bv's updated_at DESC)", got, want)
		}
	})

	t.Run("by id without updated_at", func(t *testing.T) {
		path := open(t,
			`CREATE TABLE issues (id TEXT PRIMARY KEY, title TEXT, status TEXT)`,
			`INSERT INTO issues VALUES ('o-2','B','open'), ('o-11','A','open')`,
		)
		got := ids(t, path)
		want := []string{"o-11", "o-2"}
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Errorf("order = %v, want %v (bv's fallback orders by id)", got, want)
		}
	})
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) &&
		(haystack == needle || len(needle) == 0 || indexOf(haystack, needle) >= 0)
}

func indexOf(h, n string) int {
	for i := 0; i+len(n) <= len(h); i++ {
		if h[i:i+len(n)] == n {
			return i
		}
	}
	return -1
}
