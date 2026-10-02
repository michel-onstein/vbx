package engine

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

type burndownShape struct {
	SprintID        string  `json:"sprint_id"`
	SprintName      string  `json:"sprint_name"`
	TotalDays       int     `json:"total_days"`
	ElapsedDays     int     `json:"elapsed_days"`
	RemainingDays   int     `json:"remaining_days"`
	TotalIssues     int     `json:"total_issues"`
	CompletedIssues int     `json:"completed_issues"`
	RemainingIssues int     `json:"remaining_issues"`
	IdealBurnRate   float64 `json:"ideal_burn_rate"`
	ActualBurnRate  float64 `json:"actual_burn_rate"`
	OnTrack         bool    `json:"on_track"`
	Projected       *string `json:"projected_complete"`
	DailyPoints     []struct {
		Remaining int `json:"remaining"`
		Completed int `json:"completed"`
	} `json:"daily_points"`
	IdealLine []struct {
		Remaining int `json:"remaining"`
	} `json:"ideal_line"`
}

// sprintWorkspace writes the fixture plus a sprint covering it.
func sprintWorkspace(t *testing.T, start, end time.Time) string {
	t.Helper()
	dir := newFixtureWorkspace(t)
	sprint := `{"id":"s1","name":"First sprint",` +
		`"start_date":"` + start.Format(time.RFC3339) + `",` +
		`"end_date":"` + end.Format(time.RFC3339) + `",` +
		`"bead_ids":["a","b","c","d"]}` + "\n"
	path := filepath.Join(dir, ".beads", "sprints.jsonl")
	if err := os.WriteFile(path, []byte(sprint), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func openSprintSession(t *testing.T, start, end time.Time) *Session {
	t.Helper()
	s, err := Open(OpenConfig{Path: sprintWorkspace(t, start, end), SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

func TestSprintListAndShow(t *testing.T) {
	now := time.Now()
	s := openSprintSession(t, now.AddDate(0, 0, -5), now.AddDate(0, 0, 5))

	var list struct {
		SprintCount int `json:"sprint_count"`
		Sprints     []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"sprints"`
	}
	list = call[struct {
		SprintCount int `json:"sprint_count"`
		Sprints     []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"sprints"`
	}](t, s, "sprint_list", nil)

	if list.SprintCount != 1 || list.Sprints[0].ID != "s1" {
		t.Fatalf("sprint list returned %+v", list)
	}

	var shown struct {
		Active bool `json:"active"`
		Issues []struct {
			ID string `json:"id"`
		} `json:"issues"`
		Missing []string `json:"missing"`
	}
	shown = call[struct {
		Active bool `json:"active"`
		Issues []struct {
			ID string `json:"id"`
		} `json:"issues"`
		Missing []string `json:"missing"`
	}](t, s, "sprint_show", map[string]any{"id": "s1"})

	if !shown.Active {
		t.Error("a sprint spanning today is not reported as active")
	}
	if len(shown.Issues) != 4 {
		t.Errorf("sprint resolved %d beads, want 4", len(shown.Issues))
	}
	if len(shown.Missing) != 0 {
		t.Errorf("unexpected missing beads: %v", shown.Missing)
	}
}

func TestSprintShowReportsMissingBeads(t *testing.T) {
	now := time.Now()
	dir := sprintWorkspace(t, now.AddDate(0, 0, -5), now.AddDate(0, 0, 5))
	// Add a bead id the workspace does not hold.
	path := filepath.Join(dir, ".beads", "sprints.jsonl")
	sprint := `{"id":"s1","name":"First sprint",` +
		`"start_date":"` + now.AddDate(0, 0, -5).Format(time.RFC3339) + `",` +
		`"end_date":"` + now.AddDate(0, 0, 5).Format(time.RFC3339) + `",` +
		`"bead_ids":["a","ghost"]}` + "\n"
	if err := os.WriteFile(path, []byte(sprint), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	var shown struct {
		Missing []string `json:"missing"`
	}
	shown = call[struct {
		Missing []string `json:"missing"`
	}](t, s, "sprint_show", map[string]any{"id": "s1"})

	// A sprint outliving one of its beads is reported rather than quietly
	// shrinking the sprint.
	if len(shown.Missing) != 1 || shown.Missing[0] != "ghost" {
		t.Errorf("missing beads reported as %v", shown.Missing)
	}
}

func TestCurrentResolvesTheActiveSprint(t *testing.T) {
	now := time.Now()
	s := openSprintSession(t, now.AddDate(0, 0, -2), now.AddDate(0, 0, 2))
	result := call[burndownShape](t, s, "burndown", map[string]any{"id": "current"})
	if result.SprintID != "s1" {
		t.Errorf("current resolved to %q", result.SprintID)
	}
	// No id at all means the same thing.
	implicit := call[burndownShape](t, s, "burndown", nil)
	if implicit.SprintID != "s1" {
		t.Errorf("an empty id resolved to %q", implicit.SprintID)
	}
}

func TestBurndownWithNoActiveSprintIsAnError(t *testing.T) {
	now := time.Now()
	// A sprint entirely in the past.
	s := openSprintSession(t, now.AddDate(0, 0, -30), now.AddDate(0, 0, -20))
	if _, err := s.Call("burndown", []byte(`{"id":"current"}`)); err == nil {
		t.Error("expected an error when no sprint is active")
	}
	if _, err := s.Call("burndown", []byte(`{"id":"nope"}`)); err == nil {
		t.Error("expected an error for an unknown sprint")
	}
}

func TestBurndownShape(t *testing.T) {
	now := time.Now()
	s := openSprintSession(t, now.AddDate(0, 0, -4), now.AddDate(0, 0, 5))
	result := call[burndownShape](t, s, "burndown", map[string]any{"id": "s1"})

	if result.TotalIssues != 4 {
		t.Errorf("sprint has %d beads, want 4", result.TotalIssues)
	}
	if result.TotalDays != result.ElapsedDays+result.RemainingDays {
		t.Errorf("days do not add up: %d != %d + %d",
			result.TotalDays, result.ElapsedDays, result.RemainingDays)
	}
	// The ideal line spans the whole sprint; the actual points stop at today.
	if len(result.IdealLine) != result.TotalDays+1 {
		t.Errorf("ideal line has %d points for %d days",
			len(result.IdealLine), result.TotalDays)
	}
	if len(result.DailyPoints) > result.ElapsedDays {
		t.Errorf("burndown has %d points but only %d days have elapsed",
			len(result.DailyPoints), result.ElapsedDays)
	}
	// The ideal line runs from the full backlog down to zero.
	if result.IdealLine[0].Remaining != 4 {
		t.Errorf("ideal line starts at %d", result.IdealLine[0].Remaining)
	}
	if last := result.IdealLine[len(result.IdealLine)-1]; last.Remaining != 0 {
		t.Errorf("ideal line ends at %d", last.Remaining)
	}
	for _, point := range result.DailyPoints {
		if point.Remaining+point.Completed != result.TotalIssues {
			t.Errorf("a daily point does not account for every bead: %+v", point)
		}
	}
}

func TestBurndownWithNothingDoneIsNotOnTrack(t *testing.T) {
	now := time.Now()
	// Four days in, nothing closed in the fixture's sprint beads.
	s := openSprintSession(t, now.AddDate(0, 0, -4), now.AddDate(0, 0, 5))
	result := call[burndownShape](t, s, "burndown", map[string]any{"id": "s1"})

	if result.CompletedIssues != 0 {
		t.Skip("the fixture closed a bead; this case no longer applies")
	}
	// There is no rate to extrapolate, and "on track" would be the wrong
	// default when time has passed and nothing has closed.
	if result.OnTrack {
		t.Error("a sprint with no progress reports itself on track")
	}
	// And no completion date is projected, rather than the epoch.
	if result.Projected != nil {
		t.Errorf("projected a date with no rate: %v", *result.Projected)
	}
}

func TestBurndownBeforeTheSprintStarts(t *testing.T) {
	now := time.Now()
	s := openSprintSession(t, now.AddDate(0, 0, 3), now.AddDate(0, 0, 10))
	result := call[burndownShape](t, s, "burndown", map[string]any{"id": "s1"})

	if result.ElapsedDays != 0 {
		t.Errorf("a future sprint reports %d days elapsed", result.ElapsedDays)
	}
	if result.RemainingDays != result.TotalDays {
		t.Error("a future sprint has already lost days")
	}
	if len(result.DailyPoints) != 0 {
		t.Errorf("a future sprint has %d burndown points", len(result.DailyPoints))
	}
	if result.ActualBurnRate != 0 {
		t.Errorf("a future sprint has a burn rate of %v", result.ActualBurnRate)
	}
}

func TestSprintsAreEmptyWithoutASprintFile(t *testing.T) {
	s := openFixture(t)
	var list struct {
		SprintCount int            `json:"sprint_count"`
		Sprints     []model.Sprint `json:"sprints"`
	}
	list = call[struct {
		SprintCount int            `json:"sprint_count"`
		Sprints     []model.Sprint `json:"sprints"`
	}](t, s, "sprint_list", nil)

	// No sprint file is a normal state, not an error.
	if list.SprintCount != 0 {
		t.Errorf("found %d sprints in a workspace with no sprint file", list.SprintCount)
	}
	if list.Sprints == nil {
		t.Error("sprints came back null rather than an empty list")
	}
}
