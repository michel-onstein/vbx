package engine

import (
	"database/sql"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
)

// loadStatsShape is bv's RobotLoadStats as it reaches JSON.
type loadStatsShape struct {
	SourcePath string   `json:"source_path"`
	Valid      int      `json:"valid"`
	Errors     int      `json:"errors"`
	Skipped    int      `json:"skipped"`
	Warnings   []string `json:"warnings"`
}

type withLoadStats struct {
	LoadStats *loadStatsShape `json:"load_stats"`
	Changed   bool            `json:"changed"`
}

// bv 0.25.2's warnings over Fixtures/dropped, measured.
var droppedWarnings = []string{
	"skipping malformed JSON on line 5: invalid character '\x00' looking for beginning of value",
	"skipping invalid issue on line 6: updated_at (2026-08-01 09:00:00 +0000 UTC) cannot be before" +
		" created_at (2026-08-05 09:00:00 +0000 UTC)",
}

func droppedFixturePath(t *testing.T) string {
	t.Helper()
	path, err := filepath.Abs(filepath.Join("..", "..", "..", "Fixtures", "dropped"))
	if err != nil {
		t.Fatal(err)
	}
	return path
}

// Every envelope over a load that dropped records carries bv's load_stats:
// the loader's own counts, the source and its warnings. bv 0.25.2 over
// Fixtures/dropped, measured: {valid 4, errors 2, skipped 0} and these two
// warnings, on every robot command.
func TestEveryEnvelopeCarriesLoadStatsWhenRecordsDropped(t *testing.T) {
	s, err := Open(OpenConfig{Path: droppedFixturePath(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	want := loadStatsShape{
		SourcePath: filepath.Join(droppedFixturePath(t), ".beads", "issues.jsonl"),
		Valid:      4, Errors: 2, Skipped: 0, Warnings: droppedWarnings,
	}
	for _, c := range []struct {
		method string
		req    any
	}{
		{"suggest", nil}, {"priority", nil}, {"next", nil}, {"insights", nil},
		{"graph_export", nil}, {"label_health", nil}, {"label_flow", nil},
		{"label_attention", nil}, {"capacity", nil}, {"sprint_list", nil},
		{"search", map[string]any{"query": "import"}},
		{"blocker_chain", map[string]any{"id": "drop-2"}},
		// Not an envelope, but what the app's badge reads.
		{"info", nil},
	} {
		got := call[withLoadStats](t, s, c.method, c.req)
		if got.LoadStats == nil {
			t.Errorf("%s: no load_stats", c.method)
			continue
		}
		if !reflect.DeepEqual(*got.LoadStats, want) {
			t.Errorf("%s: load_stats = %+v, want %+v", c.method, *got.LoadStats, want)
		}
	}
}

// A load that dropped nothing has no load_stats at all — not one of zeros.
func TestLoadStatsAreAbsentWhenNothingDropped(t *testing.T) {
	s := openDemo(t)
	for _, method := range []string{"next", "graph_export", "label_flow", "info"} {
		if got := call[withLoadStats](t, s, method, nil); got.LoadStats != nil {
			t.Errorf("%s: load_stats = %+v over a clean load, want none", method, *got.LoadStats)
		}
	}
}

// bv's robotLoadStats, over its source authority: sums every source that is
// not disabled, names the source only when there is exactly one, and takes
// the warnings in bv's source order, each capped and bounded.
func TestRobotLoadStatsFollowsBv(t *testing.T) {
	if got := robotLoadStats(nil); got != nil {
		t.Errorf("no sources: %+v, want nil", got)
	}
	clean := sourceLoad{sourcePath: "/a.jsonl", stats: loader.ParseStats{Valid: 3, Skipped: 1}}
	if got := robotLoadStats([]sourceLoad{clean}); got != nil {
		t.Errorf("nothing dropped: %+v, want nil (skipped records are not drops)", got)
	}

	long := strings.Repeat("é", maxWarningRunes+5)
	many := make([]string, 12)
	for i := range many {
		many[i] = "b" + string(rune('a'+i))
	}
	sources := []sourceLoad{
		{name: "web", repoPath: "web", sourcePath: "/web.jsonl",
			stats: loader.ParseStats{Valid: 2, Errors: 1}, warnings: many},
		{name: "api", repoPath: "api", sourcePath: "/api.jsonl",
			stats: loader.ParseStats{Valid: 5, Errors: 1, Skipped: 2}, warnings: []string{long}},
		{name: "off", repoPath: "off", disabled: true,
			stats: loader.ParseStats{Valid: 100, Errors: 100}},
	}
	got := robotLoadStats(sources)
	if got == nil {
		t.Fatal("nil, want stats")
	}
	if got.Valid != 7 || got.Errors != 2 || got.Skipped != 2 {
		t.Errorf("counts = %+v, want 7/2/2 (the disabled member counts for nothing)", got)
	}
	if got.SourcePath != "" {
		t.Errorf("source_path = %q with three sources, want none", got.SourcePath)
	}
	if len(got.Warnings) != maxSourceWarnings {
		t.Fatalf("%d warnings, want the cap of %d", len(got.Warnings), maxSourceWarnings)
	}
	// api sorts before web by repository path, so its warning leads.
	if want := string([]rune(long)[:maxWarningRunes]) + "…"; got.Warnings[0] != want {
		t.Errorf("first warning is not api's, bounded: %d runes", len([]rune(got.Warnings[0])))
	}
	if got.Warnings[1] != "ba" || got.Warnings[9] != "bi" {
		t.Errorf("warnings = %v, want web's after api's, in order", got.Warnings)
	}
	if sources[0].name != "web" {
		t.Error("robotLoadStats reordered its caller's slice")
	}

	// One source, even beside a disabled one, is not "exactly one source".
	one := robotLoadStats([]sourceLoad{sources[1]})
	if one == nil || one.SourcePath != "/api.jsonl" {
		t.Errorf("one source: %+v, want its path named", one)
	}
}

// A beads.db row bv's SQLite reader drops — failed validation, a repeated id
// — vbx's drops too, and counts, in bv's words. Before vbx-dv5 vbx kept the
// invalid row, so the same bead was in the graph from a beads.db and dropped
// from a JSONL.
func TestLoadSQLiteDropsAndCountsWhatBvDrops(t *testing.T) {
	path := filepath.Join(t.TempDir(), "beads.db")
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`CREATE TABLE issues (id TEXT, title TEXT, status TEXT, created_at TEXT, updated_at TEXT)`,
		`INSERT INTO issues VALUES
			('k-1','Kept','open','2026-08-01T09:00:00Z','2026-08-02T09:00:00Z'),
			('k-2','Backwards','open','2026-08-05T09:00:00Z','2026-08-01T09:00:00Z'),
			('k-3','','open','2026-08-01T09:00:00Z','2026-08-01T09:00:00Z'),
			('k-1','Again','open','2026-08-01T09:00:00Z','2026-08-01T09:00:00Z')`,
	} {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("exec %q: %v", stmt, err)
		}
	}
	db.Close()

	issues, stats, dropped, err := LoadSQLite(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(issues) != 1 || issues[0].ID != "k-1" || issues[0].Title != "Kept" {
		t.Errorf("kept %+v, want k-1 alone", issues)
	}
	if stats != (loader.ParseStats{Valid: 1, Errors: 3}) {
		t.Errorf("stats = %+v, want 1 valid and 3 errors", stats)
	}
	want := []string{
		`invalid issue "k-2": updated_at (2026-08-01 09:00:00 +0000 UTC) cannot be before` +
			` created_at (2026-08-05 09:00:00 +0000 UTC)`,
		`invalid issue "k-3": issue title cannot be empty`,
		`duplicate issue ID "k-1"`,
	}
	if !reflect.DeepEqual(dropped, want) {
		t.Errorf("warnings = %q, want %q", dropped, want)
	}
}

// Regression (vbx-dv5): a dropped record changes no record that survived, so
// the reload's hash gate cannot see one appear. Appending a malformed line
// must still bring load_stats up to date and report the change, or the app's
// badge keeps saying nothing was dropped.
func TestReloadFollowsADroppedRecordTheHashCannotSee(t *testing.T) {
	dir := newFixtureWorkspace(t)
	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	if got := call[withLoadStats](t, s, "info", nil); got.LoadStats != nil {
		t.Fatalf("clean fixture has load_stats %+v", *got.LoadStats)
	}

	path := filepath.Join(dir, ".beads", "issues.jsonl")
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("{\"id\": \"cut-off\",\n"); err != nil {
		t.Fatal(err)
	}
	file.Close()

	got := call[withLoadStats](t, s, "reload", nil)
	if !got.Changed {
		t.Error("reload did not report the dropped record as a change")
	}
	if got.LoadStats == nil || got.LoadStats.Errors != 1 {
		t.Errorf("load_stats after reload = %+v, want one error", got.LoadStats)
	}
	if env := call[withLoadStats](t, s, "graph_export", nil); env.LoadStats == nil {
		t.Error("the robot envelope did not follow the reload")
	}
	if again := call[withLoadStats](t, s, "reload", nil); again.Changed {
		t.Error("a second reload of the same file reported a change")
	}
}

// workspaceClaimSafe is bv's newRobotSourceAuthority verdict: any enabled
// member that failed, dropped a record or read a stale fallback withholds the
// claim; disabled members count for nothing; and a workspace with no loaded
// member is unknown, never safe. vbx-koc.
func TestWorkspaceClaimSafeFollowsBVsSourceAuthority(t *testing.T) {
	ok := sourceLoad{name: "ok", stats: loader.ParseStats{Valid: 2}}
	cases := []struct {
		name    string
		sources []sourceLoad
		want    bool
	}{
		{"every member clean", []sourceLoad{ok, ok}, true},
		{"a member dropped a record",
			[]sourceLoad{ok, {name: "web", stats: loader.ParseStats{Valid: 1, Errors: 1}}}, false},
		{"a member failed", []sourceLoad{ok, {name: "web", failed: true}}, false},
		{"a member read a stale fallback", []sourceLoad{ok, {name: "web", stale: true}}, false},
		{"a disabled member's errors do not count",
			[]sourceLoad{ok, {name: "off", disabled: true, failed: true, stats: loader.ParseStats{Errors: 3}}}, true},
		{"nothing loaded", []sourceLoad{{name: "off", disabled: true}}, false},
		{"no members", nil, false},
	}
	for _, c := range cases {
		if got := workspaceClaimSafe(c.sources); got != c.want {
			t.Errorf("%s: claim safe = %v, want %v", c.name, got, c.want)
		}
	}
}

// A workspace's load_stats sums its members, as bv's workspace authority
// does, and names no single source.
func TestWorkspaceLoadStatsSumTheMembers(t *testing.T) {
	root := multiRepoWorkspace(t)
	web := filepath.Join(root, "web", ".beads", "issues.jsonl")
	file, err := os.OpenFile(web, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("not json\n"); err != nil {
		t.Fatal(err)
	}
	file.Close()

	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	got := call[withLoadStats](t, s, "graph_export", nil)
	if got.LoadStats == nil {
		t.Fatal("no load_stats over a workspace whose member dropped a line")
	}
	if got.LoadStats.Valid != 3 || got.LoadStats.Errors != 1 || got.LoadStats.SourcePath != "" {
		t.Errorf("load_stats = %+v, want 3 valid across both members, 1 error, no source_path",
			*got.LoadStats)
	}
	if len(got.LoadStats.Warnings) != 1 || !strings.Contains(got.LoadStats.Warnings[0], "line 2") {
		t.Errorf("warnings = %q, want web's one", got.LoadStats.Warnings)
	}
}
