package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// The bv 0.25 burndown: bv's own at-risk detector, the closed-now rule for the
// daily points, and the scope-aware ideal line. Expectations marked "bv
// 0.25.2" were read from `bv --robot-burndown` itself over the same data at
// the same pinned clock; parity-check.py repeats the fixture comparison.

type atRiskShape struct {
	ID       string   `json:"id"`
	Priority int      `json:"priority"`
	Signals  []string `json:"signals"`
	Since    string   `json:"since"`
	Detail   string   `json:"detail"`
}

type scopeChangeShape struct {
	Date    time.Time `json:"date"`
	IssueID string    `json:"issue_id"`
	Title   string    `json:"issue_title"`
	Action  string    `json:"action"`
}

type burndownV025 struct {
	burndownShape
	AtRisk       []atRiskShape      `json:"at_risk"`
	ScopeChanges []scopeChangeShape `json:"scope_changes"`
}

func sprintsFixturePath(t *testing.T) string {
	t.Helper()
	path, err := filepath.Abs(filepath.Join("..", "..", "..", "Fixtures", "sprints"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(path, ".beads", "sprints.jsonl")); err != nil {
		t.Fatalf("sprints fixture missing: %v", err)
	}
	return path
}

func TestBurndownOverTheSprintsFixtureMatchesBV(t *testing.T) {
	// parity-check.py's PINNED_CLOCK: day 13 of Sprint 2's 14.
	setClock(t, readinessClock)
	s, err := Open(OpenConfig{Path: sprintsFixturePath(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	got := call[burndownV025](t, s, "burndown", map[string]any{"id": "spr-sprint-2"})

	// bv 0.25.2: the tombstone and the missing id are not sprint beads.
	if got.TotalIssues != 10 || got.CompletedIssues != 3 || got.RemainingIssues != 7 {
		t.Errorf("issues total/completed/remaining = %d/%d/%d, want 10/3/7 (bv 0.25.2)",
			got.TotalIssues, got.CompletedIssues, got.RemainingIssues)
	}
	if got.TotalDays != 14 || got.ElapsedDays != 13 || got.RemainingDays != 1 {
		t.Errorf("days total/elapsed/remaining = %d/%d/%d, want 14/13/1",
			got.TotalDays, got.ElapsedDays, got.RemainingDays)
	}
	if got.OnTrack {
		t.Error("3 of 10 closed with a day left reports on track")
	}

	// spr-4 is open again but kept the closed_at of an earlier close. Before
	// the bv 0.25 port it was counted from 2026-08-20 on, so the actual line
	// read one bead better than the truth for the rest of the sprint.
	want := []int{10, 9, 9, 9, 8, 8, 8, 8, 7, 7, 7, 7, 7} // bv 0.25.2
	remaining := make([]int, len(got.DailyPoints))
	for i, point := range got.DailyPoints {
		remaining[i] = point.Remaining
	}
	if !slices.Equal(remaining, want) {
		t.Errorf("daily remaining = %v, want %v (bv 0.25.2)", remaining, want)
	}

	// bv 0.25.2's four signals, bead by bead.
	wantRisk := map[string][]string{
		"spr-5": {"blocked_too_long", "no_activity", "critical_blocked", "blockers_not_closing"},
		"spr-6": {"no_activity"},
		"spr-8": {"critical_blocked"},
		"spr-9": {"blocked_too_long", "no_activity", "blockers_not_closing"},
	}
	if len(got.AtRisk) != len(wantRisk) {
		t.Fatalf("at_risk has %d beads, want %d: %+v", len(got.AtRisk), len(wantRisk), got.AtRisk)
	}
	for _, item := range got.AtRisk {
		if !slices.Equal(item.Signals, wantRisk[item.ID]) {
			t.Errorf("%s signals = %v, want %v", item.ID, item.Signals, wantRisk[item.ID])
		}
	}
	// A blocker outside the sprint still counts, and its idleness dates it.
	if spr9 := got.AtRisk[3]; spr9.ID != "spr-9" || spr9.Since != "2026-08-01T09:00:00Z" {
		t.Errorf("spr-9 at risk since %q, want spr-12's last activity", spr9.Since)
	}

	// The fixture is not a repository root, so — as in bv — there is no
	// scope history, and the key is absent rather than an empty list.
	raw, err := s.Call("burndown", []byte(`{"id":"spr-sprint-2"}`))
	if err != nil {
		t.Fatal(err)
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(raw, &keys); err != nil {
		t.Fatal(err)
	}
	if _, ok := keys["scope_changes"]; ok {
		t.Error("scope_changes is present for a workspace with no repository")
	}
}

func TestAtRiskIsAnEmptyListNotAbsent(t *testing.T) {
	setClock(t, readinessClock)
	s, err := Open(OpenConfig{Path: sprintsFixturePath(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	// Sprint 1's beads are all closed: nothing is at risk, and that is an
	// answer the UI can state, not a metric it lacks.
	raw, err := s.Call("burndown", []byte(`{"id":"spr-sprint-1"}`))
	if err != nil {
		t.Fatal(err)
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(raw, &keys); err != nil {
		t.Fatal(err)
	}
	if string(keys["at_risk"]) != "[]" {
		t.Errorf("at_risk = %s, want []", keys["at_risk"])
	}
}

// scopeRepo builds a repository whose sprint gains spr-c on day 3 and loses
// spr-b on day 6.
func scopeRepo(t *testing.T) string {
	t.Helper()
	b := newRepo(t)
	b.write(".beads/issues.jsonl",
		bead("spr-a", "Alpha", "open")+"\n"+bead("spr-b", "Bravo", "open")+"\n"+
			bead("spr-c", "Charlie", "open")+"\n")
	sprint := func(ids string) string {
		return `{"id":"s1","name":"Scoped","start_date":"2026-01-01T00:00:00Z",` +
			`"end_date":"2026-01-10T23:59:59Z","bead_ids":[` + ids + `]}` + "\n"
	}
	b.write(".beads/sprints.jsonl", sprint(`"spr-a","spr-b"`))
	b.commit("Plan the sprint", "michel") // 2026-01-01 10:00, the root commit

	b.when = time.Date(2026, 1, 4, 9, 0, 0, 0, time.UTC)
	b.write(".beads/sprints.jsonl", sprint(`"spr-a","spr-b","spr-c"`))
	b.commit("Pull spr-c into the sprint", "michel") // 2026-01-04 10:00

	b.when = time.Date(2026, 1, 7, 9, 0, 0, 0, time.UTC)
	b.write(".beads/sprints.jsonl", sprint(`"spr-a","spr-c"`))
	b.commit("Drop spr-b from the sprint", "michel") // 2026-01-07 10:00

	// After the clock below: outside the window, so not a scope change.
	b.when = time.Date(2026, 1, 9, 9, 0, 0, 0, time.UTC)
	b.write(".beads/sprints.jsonl", sprint(`"spr-a"`))
	b.commit("Drop spr-c too, later", "michel")
	// Leave the working tree at the in-window sprint, which is what the
	// burndown counts from.
	b.write(".beads/sprints.jsonl", sprint(`"spr-a","spr-c"`))
	return b.dir
}

func TestBurndownScopeChangesReadTheObjectStore(t *testing.T) {
	setClock(t, time.Date(2026, 1, 8, 12, 0, 0, 0, time.UTC))
	s, err := Open(OpenConfig{Path: scopeRepo(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	got := call[burndownV025](t, s, "burndown", map[string]any{"id": "s1"})

	type event struct{ id, action, date string }
	var events []event
	for _, change := range got.ScopeChanges {
		events = append(events, event{change.IssueID, change.Action, change.Date.Format(time.RFC3339)})
	}
	// bv 0.25.2 over the same repository, by `git log -p`.
	want := []event{
		{"spr-c", "added", "2026-01-04T10:00:00Z"},
		{"spr-b", "removed", "2026-01-07T10:00:00Z"},
	}
	if !slices.Equal(events, want) {
		t.Fatalf("scope changes = %v, want %v", events, want)
	}
	if got.ScopeChanges[0].Title != "Charlie" {
		t.Errorf("an added bead carries title %q", got.ScopeChanges[0].Title)
	}

	// The ideal line re-linearises at each change instead of running straight
	// from the final scope: two beads at the start, three once spr-c joins,
	// one once spr-b leaves, zero at the end — bv 0.25.2's line exactly,
	// truncating arithmetic included.
	ideal := make([]int, len(got.IdealLine))
	for i, point := range got.IdealLine {
		ideal[i] = point.Remaining
	}
	wantIdeal := []int{2, 2, 2, 3, 3, 3, 1, 1, 1, 1, 0}
	if !slices.Equal(ideal, wantIdeal) {
		t.Errorf("ideal line = %v, want %v", ideal, wantIdeal)
	}
}

func TestIdealLineWithoutScopeChangesIsStraight(t *testing.T) {
	sprint := &model.Sprint{
		ID:        "s",
		StartDate: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		EndDate:   time.Date(2026, 1, 7, 0, 0, 0, 0, time.UTC),
	}
	plain := idealLine(sprint, 7)
	got := make([]int, len(plain))
	for i, point := range plain {
		got[i] = point.Remaining
	}
	if want := []int{7, 6, 5, 4, 3, 2, 1, 0}; !slices.Equal(got, want) {
		t.Errorf("straight line = %v, want %v", got, want)
	}

	// Events outside the window change nothing: before the start they are
	// the starting scope, after the end they were never the plan.
	outside := []scopeChange{
		{Date: sprint.StartDate.Add(-time.Hour), Action: scopeAdded},
		{Date: sprint.EndDate.AddDate(0, 0, 3), Action: scopeRemoved},
	}
	if !slices.Equal(idealLineScoped(sprint, 7, outside), plain) {
		t.Error("out-of-window scope changes bent the ideal line")
	}

	// An empty sprint has no line, rather than a flat zero.
	if line := idealLine(sprint, 0); len(line) != 0 {
		t.Errorf("an empty sprint drew %d ideal points", len(line))
	}
}

func TestSprintWithoutDatesHasNoDays(t *testing.T) {
	// bv counts no days for a sprint missing a date, rather than the span
	// back to the zero time.
	payload, _ := burndownPayload(&model.Sprint{ID: "s", BeadIDs: []string{"a"}},
		[]model.Issue{{ID: "a", Status: model.StatusOpen}}, readinessClock)
	if payload["total_days"] != 0 || payload["elapsed_days"] != 0 {
		t.Errorf("an undated sprint has total %v, elapsed %v days",
			payload["total_days"], payload["elapsed_days"])
	}
	if points := payload["daily_points"].([]model.BurndownPoint); len(points) != 0 {
		t.Errorf("an undated sprint has %d daily points", len(points))
	}
}
