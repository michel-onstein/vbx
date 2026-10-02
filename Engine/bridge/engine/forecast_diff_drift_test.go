package engine

import (
	"encoding/json"
	"runtime"
	"strings"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/baseline"
)

// vbx-9gl: --robot-forecast, --robot-diff and --robot-drift answer over bv
// 0.25.2's --label/--recipe scope, in bv's shapes. vbx-cli used to refuse
// either flag with them; before that it answered over every bead. Expected
// values are bv 0.25.2's over the same input at the pinned clock.

type forecastShape struct {
	scopeEnvelope
	Agents        int               `json:"agents"`
	ForecastCount int               `json:"forecast_count"`
	Filters       map[string]string `json:"filters"`
	Forecasts     []struct {
		IssueID          string  `json:"issue_id"`
		EstimatedMinutes int     `json:"estimated_minutes"`
		EstimatedDays    float64 `json:"estimated_days"`
		ETADate          string  `json:"eta_date"`
	} `json:"forecasts"`
	Summary *struct {
		TotalMinutes int `json:"total_minutes"`
	} `json:"summary"`
}

func forecastIDs(f forecastShape) string {
	ids := make([]string, 0, len(f.Forecasts))
	for _, forecast := range f.Forecasts {
		ids = append(ids, forecast.IssueID)
	}
	return strings.Join(ids, ",")
}

func TestForecastAnswersOverTheScope(t *testing.T) {
	setClock(t, readinessClock)
	s := openDemoFull(t)

	// Every open bead, the closed ones skipped, with bv's summary.
	all := call[forecastShape](t, s, "forecast", map[string]any{"target": "all"})
	if forecastIDs(all) != "vbx-3,vbx-4,vbx-5,vbx-6,vbx-7,vbx-8,vbx-9,vbx-10,vbx-11,vbx-12,"+
		"vbx-13,vbx-14,vbx-16,vbx-17,vbx-18" || all.ForecastCount != 15 ||
		all.Summary == nil || all.Summary.TotalMinutes != 15981 {
		t.Errorf("forecast all = %s (%d), summary %+v", forecastIDs(all), all.ForecastCount, all.Summary)
	}
	if all.Scope != nil || !strings.HasPrefix(all.DataHash, "0e588914e7e6") ||
		all.ScopeHash != "ae83d9fe042335945c1da01cec2e6ad03d1344e2727c0e25514fd0e2d75b8d1f" {
		t.Errorf("forecast all envelope = %+v", all.scopeEnvelope)
	}

	// Under a label, only its beads are forecast, and the envelope hashes
	// the scoped issues rather than carrying the unscoped hash.
	engine := call[forecastShape](t, s, "forecast", map[string]any{"target": "all", "label": "engine"})
	if forecastIDs(engine) != "vbx-10,vbx-16,vbx-3" || engine.Scope == nil ||
		engine.Scope.Label != "engine" ||
		engine.DataHash != "73c09d5e42bc2a3a13ba3279636a38dcac31602cf2a4c7601cf918d002e6158a" ||
		engine.ScopeHash != "f08082450fccf5e8692b6226adb8fa477d65b100c5d0983b022353e2901a3db7" {
		t.Errorf("forecast all --label engine = %s, envelope %+v", forecastIDs(engine), engine.scopeEnvelope)
	}

	// --forecast-label filters the targets; it is not the scope.
	ui := call[forecastShape](t, s, "forecast", map[string]any{"target": "all", "forecast_label": "ui"})
	if forecastIDs(ui) != "vbx-4,vbx-5,vbx-6,vbx-7,vbx-8,vbx-9,vbx-13,vbx-17,vbx-18" ||
		ui.Filters["label"] != "ui" || ui.Scope != nil {
		t.Errorf("forecast all --forecast-label ui = %s, filters %v", forecastIDs(ui), ui.Filters)
	}
	none := call[forecastShape](t, s, "forecast",
		map[string]any{"target": "all", "label": "engine", "forecast_label": "ui"})
	if none.ForecastCount != 0 || none.Forecasts == nil || none.Summary != nil {
		t.Errorf("forecast with no targets = %+v", none)
	}

	// One bead, over three agents: no summary for a single forecast.
	one := call[forecastShape](t, s, "forecast", map[string]any{"target": "vbx-6", "agents": 3})
	if one.Agents != 3 || one.ForecastCount != 1 || one.Summary != nil ||
		one.Forecasts[0].EstimatedMinutes != 2629 || one.Forecasts[0].ETADate != "2026-09-05T17:56:00Z" {
		t.Errorf("forecast vbx-6 over three agents = %+v", one)
	}
}

func TestForecastRefusesWhatItCannotTarget(t *testing.T) {
	setClock(t, readinessClock)
	s := openDemoFull(t)
	for _, tc := range []struct {
		req  map[string]any
		want string
	}{
		// vbx-12 neighbours the ui label without carrying it: in the
		// scope's issues, not among its candidates.
		{map[string]any{"target": "vbx-12", "label": "ui"},
			"Issue not found in selected forecast scope: vbx-12"},
		{map[string]any{"target": "no-such-bead"},
			"Issue not found in selected forecast scope: no-such-bead"},
		{map[string]any{"target": "all", "forecast_sprint": "no-such-sprint"},
			"Sprint not found: no-such-sprint"},
		{map[string]any{}, "forecast requires a \"target\""},
	} {
		raw, _ := json.Marshal(tc.req)
		_, err := s.Call("forecast", raw)
		if err == nil || !strings.HasPrefix(err.Error(), tc.want) {
			t.Errorf("forecast %s: error %v, want %q", raw, err, tc.want)
		}
	}
}

// scopedHistoryRepo is a repository whose beads carry labels and a
// tombstone: two parser beads, a ui bead blocked by one of them, and a spike
// deleted after the first commit.
func scopedHistoryRepo(t *testing.T) string {
	t.Helper()
	b := newRepo(t)
	record := func(id, status, label, extra string) string {
		return `{"id":"` + id + `","title":"` + id + `","status":"` + status +
			`","issue_type":"task","priority":1,"created_at":"2026-01-01T00:00:00Z",` +
			`"updated_at":"2026-01-02T00:00:00Z","labels":["` + label + `"]` + extra + `}`
	}
	blocked := `,"dependencies":[{"issue_id":"ui-1","depends_on_id":"p-2","type":"blocks",` +
		`"created_at":"2026-01-01T00:00:00Z"}]`
	b.write(".beads/issues.jsonl", strings.Join([]string{
		record("p-1", "open", "parser", ""),
		record("p-2", "open", "parser", ""),
		record("ui-1", "open", "ui", blocked),
		record("spike-1", "open", "spike", ""),
	}, "\n")+"\n")
	b.commit("Add the beads", "ada")

	b.write(".beads/issues.jsonl", strings.Join([]string{
		record("p-1", "closed", "parser", `,"closed_at":"2026-01-02T00:00:00Z"`),
		record("p-2", "in_progress", "parser", ""),
		record("ui-1", "open", "ui", blocked),
		record("spike-1", "tombstone", "spike", `,"deleted_at":"2026-01-02T00:00:00Z"`),
		record("ui-2", "open", "ui", ""),
	}, "\n")+"\n")
	b.commit("Close p-1, drop the spike, add ui-2", "ada")
	return b.dir
}

type robotDiffShape struct {
	scopeEnvelope
	ResolvedRevision string `json:"resolved_revision"`
	FromDataHash     string `json:"from_data_hash"`
	ToDataHash       string `json:"to_data_hash"`
	Diff             struct {
		FromTimestamp string `json:"from_timestamp"`
		ToTimestamp   string `json:"to_timestamp"`
		NewIssues     []struct {
			ID string `json:"id"`
		} `json:"new_issues"`
		RemovedIssues []struct {
			ID string `json:"id"`
		} `json:"removed_issues"`
		ClosedIssues []struct {
			ID string `json:"id"`
		} `json:"closed_issues"`
		ModifiedIssues []struct {
			IssueID string `json:"issue_id"`
		} `json:"modified_issues"`
	} `json:"diff"`
	Badges map[string]string `json:"badges"`
}

func diffIDs(items []struct {
	ID string `json:"id"`
}) string {
	ids := make([]string, 0, len(items))
	for _, item := range items {
		ids = append(ids, item.ID)
	}
	return strings.Join(ids, ",")
}

func TestDiffComparesTheWholeRevisionWithTheScope(t *testing.T) {
	setClock(t, readinessClock)
	s, err := Open(OpenConfig{Path: scopedHistoryRepo(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	whole := call[robotDiffShape](t, s, "diff", map[string]any{"revision": "HEAD~1"})
	// A bead tombstoned since the revision is removed, as bv's loaders drop
	// tombstones on both sides; it used to read as modified.
	if diffIDs(whole.Diff.RemovedIssues) != "spike-1" || diffIDs(whole.Diff.NewIssues) != "ui-2" ||
		diffIDs(whole.Diff.ClosedIssues) != "p-1" || whole.Badges["spike-1"] != "removed" {
		t.Errorf("unscoped diff: removed %s, new %s, closed %s, badges %v",
			diffIDs(whole.Diff.RemovedIssues), diffIDs(whole.Diff.NewIssues),
			diffIDs(whole.Diff.ClosedIssues), whole.Badges)
	}
	// bv's snapshots: no from-time, the pinned clock as the to-time.
	if whole.Diff.FromTimestamp != "0001-01-01T00:00:00Z" ||
		whole.Diff.ToTimestamp != "2026-08-29T10:40:00Z" {
		t.Errorf("diff timestamps %s -> %s", whole.Diff.FromTimestamp, whole.Diff.ToTimestamp)
	}
	if whole.Scope != nil || whole.ScopeHash == "" || whole.DataHash != whole.ToDataHash {
		t.Errorf("unscoped diff envelope = %+v, to_data_hash %s", whole.scopeEnvelope, whole.ToDataHash)
	}

	// Under --label parser the current side is the parser subgraph — its
	// beads and ui-1, which p-2 blocks — so ui-2 is not new, and the beads
	// outside the scope read as removed.
	parser := call[robotDiffShape](t, s, "diff", map[string]any{"revision": "HEAD~1", "label": "parser"})
	if diffIDs(parser.Diff.NewIssues) != "" || diffIDs(parser.Diff.RemovedIssues) != "spike-1" ||
		diffIDs(parser.Diff.ClosedIssues) != "p-1" {
		t.Errorf("diff --label parser: new %s, removed %s, closed %s",
			diffIDs(parser.Diff.NewIssues), diffIDs(parser.Diff.RemovedIssues),
			diffIDs(parser.Diff.ClosedIssues))
	}
	// The hashes stay the unscoped ones; the scope is named and hashed.
	if parser.Scope == nil || parser.Scope.Label != "parser" || parser.ToDataHash != whole.ToDataHash ||
		parser.DataHash != whole.DataHash || parser.ScopeHash == whole.ScopeHash {
		t.Errorf("diff --label parser envelope = %+v", parser.scopeEnvelope)
	}

	// An unknown label is an empty current side: everything was removed.
	unknown := call[robotDiffShape](t, s, "diff", map[string]any{"revision": "HEAD~1", "label": "no-such-label"})
	if diffIDs(unknown.Diff.RemovedIssues) != "p-1,p-2,spike-1,ui-1" {
		t.Errorf("diff --label no-such-label removed %s", diffIDs(unknown.Diff.RemovedIssues))
	}

	// A recipe that does not resolve fails, as every scoped command does.
	if _, err := s.Call("diff", []byte(`{"revision":"HEAD~1","recipe":"no-such-recipe"}`)); err == nil {
		t.Error("diff accepted a recipe that does not resolve")
	}
}

type robotDriftShape struct {
	HasDrift bool `json:"has_drift"`
	ExitCode int  `json:"exit_code"`
	Summary  struct {
		Critical int `json:"critical"`
		Warning  int `json:"warning"`
		Info     int `json:"info"`
	} `json:"summary"`
	Alerts []struct {
		Type string `json:"type"`
	} `json:"alerts"`
	Baseline map[string]any `json:"baseline"`
	// Present only if an envelope leaked in: bv's drift has none.
	DataHash  *string `json:"data_hash"`
	ScopeHash *string `json:"scope_hash"`
}

func TestDriftIsBvsCheckDrift(t *testing.T) {
	setClock(t, readinessClock)
	dir := newFixtureWorkspace(t)
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	// Without a baseline, bv's error text, first line first.
	if _, err := s.Call("drift", nil); err == nil ||
		!strings.HasPrefix(err.Error(), "Error: No baseline found.\n") {
		t.Errorf("drift without a baseline: %v", err)
	}

	call[baselineShape](t, s, "baseline_save", map[string]any{"description": "now"})
	same := call[robotDriftShape](t, s, "drift", nil)
	// Against an identical baseline nothing drifts. --robot-alerts adds the
	// issue-derived checks — this fixture's beads are months stale — but bv's
	// --check-drift attaches no issues, so none of those fire here.
	if same.HasDrift || same.ExitCode != 0 || len(same.Alerts) != 0 {
		t.Errorf("drift against itself = %+v", same)
	}
	if same.DataHash != nil || same.ScopeHash != nil {
		t.Error("drift carries a robot envelope; bv's has none")
	}
	if _, ok := same.Baseline["created_at"]; !ok {
		t.Errorf("drift baseline = %v, want its created_at", same.Baseline)
	}

	// Under an unknown label the scope is empty, so every count fell.
	scoped := call[robotDriftShape](t, s, "drift", map[string]any{"label": "no-such-label"})
	types := map[string]bool{}
	for _, alert := range scoped.Alerts {
		types[alert.Type] = true
	}
	if !scoped.HasDrift || !types["node_count_change"] {
		t.Errorf("drift --label no-such-label = %+v", scoped)
	}
	// bv's exit code: 1 for critical drift, 2 for a warning, else 0.
	want := 0
	switch {
	case scoped.Summary.Critical > 0:
		want = 1
	case scoped.Summary.Warning > 0:
		want = 2
	}
	if scoped.ExitCode != want {
		t.Errorf("drift exit code %d for %+v, want %d", scoped.ExitCode, scoped.Summary, want)
	}
}

// Regression: baseline_save read the session's top metrics without waiting
// for Phase 2, so a baseline saved while it ran recorded none, and every later
// drift check reported each bead as having entered the PageRank top. The race
// is the scheduler's: it showed when other sessions' Phase 2 kept every CPU
// busy. So every CPU is kept busy here, and the save is repeated on fresh
// sessions. Without the fix this fails some runs, not every one — mostly the
// first save in a cold process — and with it never; TestDriftIsBvsCheckDrift
// and TestDriftAgainstAnUnchangedBaselineIsClean flaked on it too.
func TestBaselineSaveWaitsForPhase2(t *testing.T) {
	done := make(chan struct{})
	defer close(done)
	for i := 0; i < 4*runtime.GOMAXPROCS(0); i++ {
		go func() {
			for {
				select {
				case <-done:
					return
				default:
				}
			}
		}()
	}
	for attempt := 0; attempt < 10; attempt++ {
		dir := newFixtureWorkspace(t)
		s, err := Open(OpenConfig{Path: dir})
		if err != nil {
			t.Fatal(err)
		}
		call[baselineShape](t, s, "baseline_save", map[string]any{"description": "early"})
		s.Close()
		saved, err := baseline.Load(baseline.DefaultPath(dir))
		if err != nil {
			t.Fatal(err)
		}
		if len(saved.TopMetrics.PageRank) == 0 {
			t.Fatalf("attempt %d: the baseline recorded no PageRank leaders", attempt)
		}
	}
}
