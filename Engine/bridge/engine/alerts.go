package engine

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/baseline"
	"github.com/Dicklesworthstone/beads_viewer/pkg/drift"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// Alerts and drift.
//
// bv has no alert engine in `pkg/analysis` — `analysis.Alert` is declared and
// never populated. Alerts are drift alerts: `pkg/drift` compares two baselines
// and emits them. What `cmd/bv` adds is the assembly, reproduced here.
//
// The one part worth naming is what happens with no saved baseline. bv builds
// the current stats and compares them *against themselves*, which sounds
// pointless but is not: the checks that read the issue list rather than the
// baseline delta — staleness, blocking cascades — still fire. Without a
// baseline you get the issue-derived alerts; with one, you also get the deltas.

// projectDir is the directory the workspace's `.bv` configuration lives in.
//
// The source is the beads file, so the project root is its grandparent:
// `<project>/.beads/issues.jsonl`.
func (s *Session) projectDir() string {
	s.mu.RLock()
	source := s.source
	s.mu.RUnlock()
	if source == "" {
		return ""
	}
	return filepath.Dir(filepath.Dir(source))
}

// currentBaselineStats summarises an analysis set the way a baseline does.
func (s *Session) currentBaselineStats(v robotView) (baseline.GraphStats, [][]string, error) {
	issues, analyzer := v.issues, v.analyzer
	if analyzer == nil {
		return baseline.GraphStats{}, nil, fmt.Errorf("session has no analyzer")
	}

	stats := analysis.NewAnalyzer(issues).Analyze()

	release := s.pinClock(analyzer)
	actionable := len(analyzer.GetActionableIssues())
	release()

	var open, closed, blocked int
	for _, issue := range issues {
		switch issue.Status {
		case model.StatusClosed:
			closed++
		case model.StatusBlocked:
			blocked++
		case model.StatusOpen, model.StatusInProgress:
			// bv counts in-progress as open here. Splitting them would make
			// claiming a bead look like closing one.
			open++
		}
	}

	cycles := stats.Cycles()
	if cycles == nil {
		cycles = [][]string{}
	}

	return baseline.GraphStats{
		NodeCount:       stats.NodeCount,
		EdgeCount:       stats.EdgeCount,
		Density:         stats.Density,
		OpenCount:       open,
		ClosedCount:     closed,
		BlockedCount:    blocked,
		CycleCount:      len(cycles),
		ActionableCount: actionable,
	}, cycles, nil
}

// topMetricItems takes the highest-scoring entries of a metric map.
//
// Ties break on id so a saved baseline is reproducible; bv sorts by value
// alone, which leaves equal values in map order and makes two baselines of
// identical data differ.
func topMetricItems(m map[string]float64, limit int) []baseline.MetricItem {
	if len(m) == 0 {
		return nil
	}
	items := make([]baseline.MetricItem, 0, len(m))
	for id, value := range m {
		items = append(items, baseline.MetricItem{ID: id, Value: value})
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].Value != items[j].Value {
			return items[i].Value > items[j].Value
		}
		return items[i].ID < items[j].ID
	})
	if len(items) > limit {
		items = items[:limit]
	}
	return items
}

// currentTopMetrics collects an analysis set's Phase-2 leaders for a baseline.
func (s *Session) currentTopMetrics(v robotView) baseline.TopMetrics {
	stats := v.stats
	if stats == nil {
		return baseline.TopMetrics{}
	}
	return baseline.TopMetrics{
		PageRank:     topMetricItems(stats.PageRank(), 10),
		Betweenness:  topMetricItems(stats.Betweenness(), 10),
		CriticalPath: topMetricItems(stats.CriticalPathScore(), 10),
		Hubs:         topMetricItems(stats.Hubs(), 10),
		Authorities:  topMetricItems(stats.Authorities(), 10),
	}
}

type alertsRequest struct {
	Severity string `json:"severity"`
	Type     string `json:"type"`
	// AlertLabel is bv's --alert-label: a filter on the alerts computed.
	AlertLabel string `json:"alert_label"`
	// The scope is bv's global --label and --recipe (scope.go): it changes
	// the issue set the alerts are computed over. bv applies the scope and
	// --alert-label both when both are given.
	scopeRequest
}

// alerts compares the workspace against its saved baseline, if any.
func (s *Session) alerts(req []byte) ([]byte, error) {
	var r alertsRequest
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}

	v, err := s.view(r.scopeRequest)
	if err != nil {
		return nil, err
	}
	result, hasBaseline, baselineInfo, err := s.computeDrift(v)
	if err != nil {
		return nil, err
	}

	filtered := filterAlerts(result.Alerts, r)
	critical, warning, info := countSeverities(filtered)

	// bv's robot envelope sits at the top level beside the alerts, as it does
	// in bv's own payload (vbx-6su).
	return s.withEnvelope(map[string]any{
		"alerts":       filtered,
		"has_baseline": hasBaseline,
		"baseline":     baselineInfo,
		"summary": map[string]any{
			"total":    len(filtered),
			"critical": critical,
			"warning":  warning,
			"info":     info,
		},
	}, v.dataHash, v.scope)
}

// computeDrift runs the drift calculator over an analysis set against the saved
// baseline. bv computes the current stats, top metrics and issue-derived alerts
// over its label-scoped set, so a label view does the same here.
func (s *Session) computeDrift(v robotView) (*drift.Result, bool, map[string]any, error) {
	dir := s.projectDir()
	if dir == "" {
		return nil, false, nil, fmt.Errorf("session has no source")
	}

	config, err := drift.LoadConfig(dir)
	if err != nil || config == nil {
		// A missing or unreadable drift.yaml means defaults, not failure.
		config = drift.DefaultConfig()
	}

	stats, cycles, err := s.currentBaselineStats(v)
	if err != nil {
		return nil, false, nil, err
	}

	current := &baseline.Baseline{Stats: stats, Cycles: cycles}
	previous := &baseline.Baseline{Stats: stats}
	hasBaseline := false
	var info map[string]any

	path := baseline.DefaultPath(dir)
	if baseline.Exists(path) {
		if saved, lerr := baseline.Load(path); lerr == nil && saved != nil {
			previous = saved
			hasBaseline = true
			current.TopMetrics = s.currentTopMetrics(v)
			info = map[string]any{
				"created_at":     saved.CreatedAt,
				"commit_sha":     saved.CommitSHA,
				"commit_message": saved.CommitMessage,
				"branch":         saved.Branch,
				"description":    saved.Description,
			}
		}
	}

	// The calculator borrows the view's analyzer, as bv's does, so a scoped
	// view's candidates bound the issue-derived checks: under a label only the
	// labelled beads can raise a cascade or a high-impact unblock, not their
	// dependency neighbours. A calculator analysing the rows afresh would treat
	// every row as a candidate. The clock is pinned throughout, because the
	// borrow requires the analyzer and the calculator to share one instant.
	release := s.pinClock(v.analyzer)
	defer release()
	calculator := drift.NewCalculator(previous, current, config)
	calculator.SetNow(v.analyzer.Now())
	calculator.SetIssues(v.issues)
	if !calculator.ReuseAnalyzer(v.analyzer) {
		return nil, false, nil, fmt.Errorf("preparing alerts: issue rows do not match the analyzer")
	}
	return calculator.Calculate(), hasBaseline, info, nil
}

// filterAlerts applies the severity, type and label filters.
func filterAlerts(alerts []drift.Alert, r alertsRequest) []drift.Alert {
	out := make([]drift.Alert, 0, len(alerts))
	for _, alert := range alerts {
		if r.Severity != "" && string(alert.Severity) != r.Severity {
			continue
		}
		if r.Type != "" && string(alert.Type) != r.Type {
			continue
		}
		if !alertMatchesLabel(alert, r.AlertLabel) {
			continue
		}
		out = append(out, alert)
	}
	return out
}

// alertMatchesLabel is bv 0.25.2's --alert-label rule, from the robot-alerts
// handler in cmd/bv/robot_registry.go, which exports no function for it.
//
// A blank label keeps everything. Otherwise, case-insensitively and after
// trimming, an alert matches when one of its issue's labels equals the label,
// when its own label equals it, or when a detail line contains it. An alert
// naming no label and no matching detail — a workspace-wide one, a new cycle or
// a density jump — is dropped, so an unknown label returns no alerts at all.
func alertMatchesLabel(alert drift.Alert, label string) bool {
	want := strings.ToLower(strings.TrimSpace(label))
	if want == "" {
		return true
	}
	for _, l := range alert.Labels {
		if strings.ToLower(l) == want {
			return true
		}
	}
	if alert.Label != "" && strings.ToLower(alert.Label) == want {
		return true
	}
	for _, detail := range alert.Details {
		if strings.Contains(strings.ToLower(detail), want) {
			return true
		}
	}
	return false
}

func countSeverities(alerts []drift.Alert) (critical, warning, info int) {
	for _, alert := range alerts {
		switch alert.Severity {
		case drift.SeverityCritical:
			critical++
		case drift.SeverityWarning:
			warning++
		default:
			info++
		}
	}
	return
}

// noBaselineError is bv's stderr when --check-drift finds no baseline, both
// lines of it.
const noBaselineError = "Error: No baseline found.\n" +
	"Create one with: bv --save-baseline \"description\""

// driftPayload is bv 0.25.2's --check-drift --robot-drift (cmd/bv/main.go),
// over the request's scope.
//
// It is not the alerts computation, and differs from it in three ways that
// are bv's, not vbx's:
//
//   - The analysis is a fresh analyzer over the scope's issues, with no
//     candidate set and no source-wide readiness: bv builds one with
//     analysis.NewAnalyzer(issues) rather than borrowing its dispatch
//     analyzer, so under --label the label's neighbours count as actionable
//     too.
//   - No issues are attached to the calculator, so only the baseline
//     comparisons run — cycles, density, size, blocked, actionable and
//     PageRank — and none of the issue-derived checks (staleness, cascades,
//     abandoned claims) that --robot-alerts adds.
//   - The output has no robot envelope: generated_at, the verdict, the exit
//     code bv exits with, and the baseline's creation time and commit.
//
// A missing baseline is bv's error text, which vbx-cli prints as bv does.
func (s *Session) driftPayload(req []byte) ([]byte, error) {
	sc, err := parseScopeRequest(req)
	if err != nil {
		return nil, err
	}
	v, err := s.view(sc)
	if err != nil {
		return nil, err
	}
	dir := s.projectDir()
	if dir == "" {
		return nil, fmt.Errorf("session has no source")
	}
	path := baseline.DefaultPath(dir)
	if !baseline.Exists(path) {
		return nil, fmt.Errorf("%s", noBaselineError)
	}
	saved, err := baseline.Load(path)
	if err != nil {
		return nil, fmt.Errorf("Error loading baseline: %v", err)
	}

	now := robotNow()
	analyzer := analysis.NewAnalyzer(v.issues)
	analyzer.SetNow(now)
	stats := analyzer.Analyze()

	var open, closed, blocked int
	for _, issue := range v.issues {
		switch issue.Status {
		case model.StatusOpen, model.StatusInProgress:
			open++
		case model.StatusClosed:
			closed++
		case model.StatusBlocked:
			blocked++
		}
	}
	cycles := stats.Cycles()
	current := &baseline.Baseline{
		Stats: baseline.GraphStats{
			NodeCount:       stats.NodeCount,
			EdgeCount:       stats.EdgeCount,
			Density:         stats.Density,
			OpenCount:       open,
			ClosedCount:     closed,
			BlockedCount:    blocked,
			CycleCount:      len(cycles),
			ActionableCount: len(analyzer.GetActionableIssues()),
		},
		TopMetrics: baseline.TopMetrics{
			PageRank:     topMetricItems(stats.PageRank(), 10),
			Betweenness:  topMetricItems(stats.Betweenness(), 10),
			CriticalPath: topMetricItems(stats.CriticalPathScore(), 10),
			Hubs:         topMetricItems(stats.Hubs(), 10),
			Authorities:  topMetricItems(stats.Authorities(), 10),
		},
		Cycles: cycles,
	}

	config, err := drift.LoadConfig(dir)
	if err != nil || config == nil {
		// bv warns outside robot mode and carries on with the defaults.
		config = drift.DefaultConfig()
	}
	calculator := drift.NewCalculator(saved, current, config)
	calculator.SetNow(now)
	result := calculator.Calculate()

	baselineInfo := map[string]any{"created_at": saved.CreatedAt.Format(time.RFC3339)}
	if saved.CommitSHA != "" {
		baselineInfo["commit_sha"] = saved.CommitSHA
	}
	return json.Marshal(map[string]any{
		"generated_at": now.Format(time.RFC3339),
		"has_drift":    result.HasDrift,
		"exit_code":    result.ExitCode(),
		"summary": map[string]any{
			"critical": result.CriticalCount,
			"warning":  result.WarningCount,
			"info":     result.InfoCount,
		},
		"alerts":   result.Alerts,
		"baseline": baselineInfo,
	})
}

type baselineRequest struct {
	Description string `json:"description"`
}

// saveBaseline records the current graph as the point future drift is measured
// from.
func (s *Session) saveBaseline(req []byte) ([]byte, error) {
	var r baselineRequest
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}

	dir := s.projectDir()
	if dir == "" {
		return nil, fmt.Errorf("session has no source")
	}

	whole := s.wholeView()
	// The top metrics are Phase 2's. Saved before it finishes, the baseline
	// records none, and every later drift check reports each bead as having
	// entered the PageRank top — bv's --save-baseline analyses synchronously.
	if whole.stats != nil {
		whole.stats.WaitForPhase2()
	}
	stats, cycles, err := s.currentBaselineStats(whole)
	if err != nil {
		return nil, err
	}

	// Not baseline.New: it runs `git` in the process's working directory,
	// which is neither the workspace nor allowed in the app (vbx-6s8).
	saved := newWorkspaceBaseline(dir, stats, s.currentTopMetrics(whole), cycles, r.Description)
	path := baseline.DefaultPath(dir)
	if err := saved.Save(path); err != nil {
		return nil, fmt.Errorf("saving baseline to %s: %w", path, err)
	}

	// `exists` is stated rather than implied: the response shares its shape
	// with baseline_info, and a caller decoding it would otherwise read the
	// baseline it just wrote as absent.
	return json.Marshal(map[string]any{
		"exists":         true,
		"path":           path,
		"created_at":     saved.CreatedAt,
		"description":    saved.Description,
		"commit_sha":     saved.CommitSHA,
		"commit_message": saved.CommitMessage,
		"branch":         saved.Branch,
		"summary":        saved.Summary(),
		"stats":          saved.Stats,
		// bv's --save-baseline output, word for word, which vbx-cli prints —
		// less the final newline, which its print adds back.
		"message": strings.TrimSuffix(
			fmt.Sprintf("Baseline saved to %s\n", path)+saved.Summary(), "\n"),
	})
}

// baselineInfo describes the saved baseline, if there is one.
func (s *Session) baselineInfo() ([]byte, error) {
	dir := s.projectDir()
	if dir == "" {
		return nil, fmt.Errorf("session has no source")
	}
	path := baseline.DefaultPath(dir)

	if !baseline.Exists(path) {
		// Not an error: having no baseline yet is the normal starting state,
		// and the UI offers to create one.
		return json.Marshal(map[string]any{"exists": false, "path": path})
	}
	saved, err := baseline.Load(path)
	if err != nil {
		return nil, fmt.Errorf("reading baseline at %s: %w", path, err)
	}
	return json.Marshal(map[string]any{
		"exists":         true,
		"path":           path,
		"created_at":     saved.CreatedAt,
		"commit_sha":     saved.CommitSHA,
		"commit_message": saved.CommitMessage,
		"branch":         saved.Branch,
		"description":    saved.Description,
		"summary":        saved.Summary(),
		"stats":          saved.Stats,
	})
}
