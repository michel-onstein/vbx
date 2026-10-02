package engine

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// Forecast: bv 0.25.2's --robot-forecast, whose handler (robot_registry.go)
// is unexported in cmd/bv and is reproduced here. The estimate itself is bv's
// analysis.EstimateETAForIssue, called rather than copied.
//
// The `eta` method is the app's single-bead estimate over every bead; this is
// the robot command, which forecasts over the scope:
//
//   - The analysis is bv's RobotContext.Analyzer: a fresh analyzer over the
//     scope's issues, with the source-wide readiness and the scope's
//     candidates, analysed in full at the pinned clock.
//   - The targets are the candidates, narrowed by --forecast-label (an exact
//     label) and --forecast-sprint (the sprint's beads). `all` forecasts every
//     target that is not closed; an id forecasts that bead, and one outside
//     the targets is bv's "not found in selected forecast scope".
//   - The envelope hashes the scope's issues, as bv's EnvelopeWithHash does
//     here, rather than carrying the unscoped hash.

type forecastRequest struct {
	// Target is a bead id, or "all".
	Target string `json:"target"`
	Agents int    `json:"agents"`
	// Label and Sprint are bv's --forecast-label and --forecast-sprint:
	// filters on the targets, distinct from the scope's --label.
	ForecastLabel  string `json:"forecast_label"`
	ForecastSprint string `json:"forecast_sprint"`
	scopeRequest
}

// forecastSummary is bv's ForecastSummary, present for more than one forecast.
type forecastSummary struct {
	TotalMinutes  int       `json:"total_minutes"`
	TotalDays     float64   `json:"total_days"`
	AvgConfidence float64   `json:"avg_confidence"`
	EarliestETA   time.Time `json:"earliest_eta"`
	LatestETA     time.Time `json:"latest_eta"`
}

func (s *Session) forecast(req []byte) ([]byte, error) {
	var r forecastRequest
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}
	if r.Target == "" {
		return nil, fmt.Errorf("forecast requires a \"target\": a bead id or \"all\"")
	}
	v, err := s.view(r.scopeRequest)
	if err != nil {
		return nil, err
	}

	now := robotNow()
	analyzer := analysis.NewAnalyzer(v.issues)
	analyzer.SetReadinessScope(s.readinessIndex(), v.candidates)
	analyzer.SetNow(now)
	stats := analyzer.Analyze()

	label := strings.TrimSpace(r.ForecastLabel) != ""
	var sprintBeads map[string]bool
	if strings.TrimSpace(r.ForecastSprint) != "" {
		// bv treats an unreadable sprint file as one without the sprint.
		sprints, _ := s.loadSprints()
		for _, sprint := range sprints {
			if sprint.ID == r.ForecastSprint {
				sprintBeads = make(map[string]bool, len(sprint.BeadIDs))
				for _, id := range sprint.BeadIDs {
					sprintBeads[id] = true
				}
				break
			}
		}
		if sprintBeads == nil {
			return nil, fmt.Errorf("Sprint not found: %s", r.ForecastSprint)
		}
	}

	targets := make([]model.Issue, 0, len(v.issues))
	for _, issue := range v.issues {
		if !analyzer.IsCandidate(issue.ID) {
			continue
		}
		// Exact and case-sensitive, as --capacity-label's is.
		if label && !hasLabel(issue, r.ForecastLabel) {
			continue
		}
		if sprintBeads != nil && !sprintBeads[issue.ID] {
			continue
		}
		targets = append(targets, issue)
	}

	agents := r.Agents
	if agents <= 0 {
		agents = 1
	}
	forecasts := make([]analysis.ETAEstimate, 0)
	if r.Target == "all" {
		for _, issue := range targets {
			if issue.Status == model.StatusClosed {
				continue
			}
			eta, err := analysis.EstimateETAForIssue(v.issues, &stats, issue.ID, agents, now)
			if err != nil {
				continue
			}
			forecasts = append(forecasts, eta)
		}
	} else {
		selected := false
		for _, issue := range targets {
			if issue.ID == r.Target {
				selected = true
				break
			}
		}
		if !selected {
			return nil, fmt.Errorf("Issue not found in selected forecast scope: %s", r.Target)
		}
		eta, err := analysis.EstimateETAForIssue(v.issues, &stats, r.Target, agents, now)
		if err != nil {
			return nil, fmt.Errorf("Error: %v", err)
		}
		forecasts = append(forecasts, eta)
	}

	output := map[string]any{
		"agents":         agents,
		"forecast_count": len(forecasts),
		"forecasts":      forecasts,
	}
	if summary := summariseForecasts(forecasts); summary != nil {
		output["summary"] = summary
	}
	filters := map[string]string{}
	if label {
		filters["label"] = r.ForecastLabel
	}
	if sprintBeads != nil {
		filters["sprint"] = r.ForecastSprint
	}
	if len(filters) > 0 {
		output["filters"] = filters
	}
	return s.withEnvelope(output, analysis.ComputeDataHash(v.issues), v.scope)
}

// summariseForecasts is bv's summary: totals and the ETA span, only when
// there is more than one forecast to summarise.
func summariseForecasts(forecasts []analysis.ETAEstimate) *forecastSummary {
	if len(forecasts) <= 1 {
		return nil
	}
	totalMinutes := 0
	totalConfidence := 0.0
	earliest, latest := forecasts[0].ETADate, forecasts[0].ETADate
	for _, forecast := range forecasts {
		totalMinutes += forecast.EstimatedMinutes
		totalConfidence += forecast.Confidence
		if forecast.ETADate.Before(earliest) {
			earliest = forecast.ETADate
		}
		if forecast.ETADate.After(latest) {
			latest = forecast.ETADate
		}
	}
	return &forecastSummary{
		TotalMinutes:  totalMinutes,
		TotalDays:     float64(totalMinutes) / (60.0 * 8.0),
		AvgConfidence: totalConfidence / float64(len(forecasts)),
		EarliestETA:   earliest,
		LatestETA:     latest,
	}
}
