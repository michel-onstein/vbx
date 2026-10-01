package engine

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/correlation"
	"github.com/Dicklesworthstone/beads_viewer/pkg/export"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// The remaining robot-protocol payloads.
//
// Some are a thin call into a public bv function; those are exact by
// construction. Others are assembled in `cmd/bv`, which is not importable, and
// are reproduced here — with the same thresholds, the same ordering and the
// same field names, because the parity harness compares them byte for byte
// against `bv` and a nearly-right payload is just a failing one.

// robotEnvelope is the header most robot payloads carry.
func (s *Session) robotEnvelope() (string, string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	hash := ""
	if s.analyzer != nil {
		hash = s.analyzer.DataHash()
	}
	return robotNow().UTC().Format(time.RFC3339), hash
}

// suggest reports hygiene problems: duplicates, missing dependencies, labels
// and cycles.
//
// The only robot command whose top-level payload *is* a `pkg/analysis` type,
// so this is exact rather than reproduced.
func (s *Session) suggest(req []byte) ([]byte, error) {
	var r struct {
		Type          string  `json:"type"`
		MinConfidence float64 `json:"min_confidence"`
		Bead          string  `json:"bead"`
	}
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}

	config := analysis.DefaultSuggestAllConfig()
	if r.MinConfidence > 0 {
		config.MinConfidence = r.MinConfidence
	}
	config.FilterBead = r.Bead

	switch strings.ToLower(r.Type) {
	case "":
		// No filter.
	case "duplicate", "duplicates":
		config.FilterType = analysis.SuggestionPotentialDuplicate
	case "dependency", "dependencies":
		config.FilterType = analysis.SuggestionMissingDependency
	case "label", "labels":
		config.FilterType = analysis.SuggestionLabelSuggestion
	case "cycle", "cycles":
		config.FilterType = analysis.SuggestionCycleWarning
	default:
		return nil, fmt.Errorf(
			"invalid suggest type %q (use: duplicate, dependency, label, cycle)", r.Type)
	}

	issues, _, _ := s.snapshot()
	_, hash := s.robotEnvelope()
	return json.Marshal(analysis.GenerateRobotSuggestOutput(issues, config, hash))
}

// priority ranks beads whose priority looks wrong, with the reasoning.
func (s *Session) priority(req []byte) ([]byte, error) {
	var r struct {
		MinConfidence float64 `json:"min_confidence"`
		MaxResults    int     `json:"max_results"`
		ByLabel       string  `json:"by_label"`
		ByAssignee    string  `json:"by_assignee"`
	}
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}

	issues, analyzer, stats := s.snapshot()
	if analyzer == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	if stats != nil {
		stats.WaitForPhase2()
	}

	byID := make(map[string]model.Issue, len(issues))
	for _, issue := range issues {
		byID[issue.ID] = issue
	}

	release := s.pinClock(analyzer)
	recommendations := analyzer.GenerateEnhancedRecommendations()
	release()

	// The filters are applied in bv's order, and each one drops a
	// recommendation whose issue is missing rather than keeping it — an
	// unresolvable recommendation cannot be acted on.
	filtered := recommendations[:0]
	for _, rec := range recommendations {
		if r.MinConfidence > 0 && rec.Confidence < r.MinConfidence {
			continue
		}
		issue, known := byID[rec.IssueID]
		if r.ByLabel != "" {
			if !known || !containsExact(issue.Labels, r.ByLabel) {
				continue
			}
		}
		if r.ByAssignee != "" {
			if !known || issue.Assignee != r.ByAssignee {
				continue
			}
		}
		filtered = append(filtered, rec)
	}

	maxResults := 10
	if r.MaxResults > 0 {
		maxResults = r.MaxResults
	}
	if len(filtered) > maxResults {
		filtered = filtered[:maxResults]
	}

	// Counted after truncation, matching bv: the number describes what was
	// returned, not what was considered.
	highConfidence := 0
	for _, rec := range filtered {
		if rec.Confidence >= 0.7 {
			highConfidence++
		}
	}

	generated, hash := s.robotEnvelope()
	filters := map[string]any{"max_results": maxResults}
	if r.MinConfidence > 0 {
		filters["min_confidence"] = r.MinConfidence
	}
	if r.ByLabel != "" {
		filters["by_label"] = r.ByLabel
	}
	if r.ByAssignee != "" {
		filters["by_assignee"] = r.ByAssignee
	}

	return json.Marshal(map[string]any{
		"generated_at":       generated,
		"data_hash":          hash,
		"recommendations":    filtered,
		"field_descriptions": analysis.DefaultFieldDescriptions(),
		"filters":            filters,
		"summary": map[string]any{
			"total_issues":    len(issues),
			"recommendations": len(filtered),
			"high_confidence": highConfidence,
		},
	})
}

func containsExact(values []string, needle string) bool {
	for _, value := range values {
		if value == needle {
			return true
		}
	}
	return false
}

// next returns the single bead that is safe to claim.
//
// The claim-safety gate is `cmd/bv`'s, and it is the reason this command
// exists at all: a recommendation can be graph-important and still be blocked,
// assigned, closed or an epic. Handing one of those to an agent as "next"
// sends it at work it cannot start.
func (s *Session) next(req []byte) ([]byte, error) {
	issues, _, stats := s.snapshot()
	if stats != nil {
		stats.WaitForPhase2()
	}

	byID := make(map[string]model.Issue, len(issues))
	for _, issue := range issues {
		byID[issue.ID] = issue
	}

	triage := analysis.ComputeTriage(issues)
	generated, hash := s.robotEnvelope()

	payload := map[string]any{
		"generated_at": generated,
		"data_hash":    hash,
		"actionable":   false,
	}
	if stats != nil {
		payload["phase2_ready"] = stats.IsPhase2Ready()
	}

	var diagnostic map[string]any
	var reasons []string

	for _, rec := range triage.Recommendations {
		blockers := claimBlockers(rec.ID, byID)
		if diagnostic == nil {
			diagnostic = map[string]any{
				"id": rec.ID, "title": rec.Title, "score": rec.Score,
			}
		}
		if len(blockers) > 0 {
			if reasons == nil {
				reasons = blockers
			}
			continue
		}

		payload["actionable"] = true
		payload["id"] = rec.ID
		payload["title"] = rec.Title
		payload["score"] = rec.Score
		payload["claim_command"] = fmt.Sprintf("br update %s --status=in_progress", rec.ID)
		payload["show_command"] = fmt.Sprintf("br show %s", rec.ID)
		return json.Marshal(payload)
	}

	// Nothing claimable. Which of the three degraded outcomes it is matters,
	// because the repair differs.
	switch {
	case len(triage.Recommendations) == 0:
		payload["message"] = "No proven actionable item available"
		payload["degraded"] = []map[string]any{{
			"code":     "no_actionable_recommendation",
			"severity": "info",
			"repair":   "Use br ready --json for authoritative claim candidates.",
		}}
	default:
		payload["message"] =
			"No claim command emitted because the top recommendation was not claim-safe"
		payload["degraded"] = []map[string]any{{
			"code":     "robot_next_claim_unsafe",
			"severity": "warning",
			"reasons":  reasons,
			"repair": "Use the authoritative Beads actionable queue plus claim gate " +
				"before claiming work.",
		}}
	}
	if diagnostic != nil {
		payload["diagnostic_top_pick"] = diagnostic
	}
	return json.Marshal(payload)
}

// claimBlockers lists why a bead cannot be claimed, in bv's order.
func claimBlockers(id string, byID map[string]model.Issue) []string {
	issue, known := byID[id]
	if !known {
		return []string{fmt.Sprintf("%s is absent from loaded Beads records", id)}
	}

	var reasons []string
	if !strings.EqualFold(strings.TrimSpace(string(issue.Status)), "open") {
		reasons = append(reasons, fmt.Sprintf("%s status is %q", id, issue.Status))
	}
	if strings.EqualFold(strings.TrimSpace(string(issue.IssueType)), "epic") {
		reasons = append(reasons, fmt.Sprintf("%s is an epic", id))
	}
	if strings.TrimSpace(issue.Assignee) != "" {
		reasons = append(reasons,
			fmt.Sprintf("%s is already assigned to %s", id, issue.Assignee))
	}

	var blocking []string
	for _, dep := range issue.Dependencies {
		if dep == nil || !dep.Type.IsBlocking() {
			continue
		}
		if dep.DependsOnID == "" {
			blocking = append(blocking, "<missing blocker id>")
			continue
		}
		blocker, exists := byID[dep.DependsOnID]
		if !exists {
			blocking = append(blocking, dep.DependsOnID+" (missing)")
			continue
		}
		if blocker.Status != model.StatusClosed && blocker.Status != model.StatusTombstone {
			blocking = append(blocking, dep.DependsOnID)
		}
	}
	if len(blocking) > 0 {
		sort.Strings(blocking)
		reasons = append(reasons,
			fmt.Sprintf("%s is blocked by %s", id, strings.Join(blocking, ", ")))
	}
	return reasons
}

// insights reports the deep graph metrics.
func (s *Session) insights(req []byte) ([]byte, error) {
	var r struct {
		Limit int `json:"limit"`
	}
	if len(req) > 0 {
		_ = json.Unmarshal(req, &r)
	}
	limit := r.Limit
	if limit <= 0 {
		limit = 200
	}

	_, analyzer, stats := s.snapshot()
	if analyzer == nil || stats == nil {
		return nil, fmt.Errorf("session has no analysis")
	}
	stats.WaitForPhase2()

	generated, hash := s.robotEnvelope()
	return json.Marshal(map[string]any{
		"generated_at": generated,
		"data_hash":    hash,
		"insights":     stats.GenerateInsights(50),
		"status":       stats.Status(),
		"full_stats": map[string]any{
			// The key names differ from the accessor names, which is bv's
			// choice and therefore ours.
			"pagerank":            limitFloatMap(stats.PageRank(), limit),
			"betweenness":         limitFloatMap(stats.Betweenness(), limit),
			"eigenvector":         limitFloatMap(stats.Eigenvector(), limit),
			"hubs":                limitFloatMap(stats.Hubs(), limit),
			"authorities":         limitFloatMap(stats.Authorities(), limit),
			"critical_path_score": limitFloatMap(stats.CriticalPathScore(), limit),
			"core_number":         limitIntMap(stats.CoreNumber(), limit),
			"slack":               limitFloatMap(stats.Slack(), limit),
			"articulation_points": limitSlice(stats.ArticulationPoints(), limit),
		},
	})
}

// limitFloatMap keeps the highest-valued entries.
//
// Ties break on key, so two runs over identical data produce identical output
// — which the parity harness depends on.
func limitFloatMap(values map[string]float64, limit int) map[string]float64 {
	if len(values) <= limit {
		return values
	}
	type entry struct {
		key   string
		value float64
	}
	entries := make([]entry, 0, len(values))
	for key, value := range values {
		entries = append(entries, entry{key, value})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].value != entries[j].value {
			return entries[i].value > entries[j].value
		}
		return entries[i].key < entries[j].key
	})
	out := make(map[string]float64, limit)
	for _, e := range entries[:limit] {
		out[e.key] = e.value
	}
	return out
}

func limitIntMap(values map[string]int, limit int) map[string]int {
	if len(values) <= limit {
		return values
	}
	type entry struct {
		key   string
		value int
	}
	entries := make([]entry, 0, len(values))
	for key, value := range values {
		entries = append(entries, entry{key, value})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].value != entries[j].value {
			return entries[i].value > entries[j].value
		}
		return entries[i].key < entries[j].key
	})
	out := make(map[string]int, limit)
	for _, e := range entries[:limit] {
		out[e.key] = e.value
	}
	return out
}

func limitSlice(values []string, limit int) []string {
	if values == nil {
		return []string{}
	}
	if len(values) <= limit {
		return values
	}
	return values[:limit]
}

// graphExport renders the dependency graph in bv's export formats.
func (s *Session) graphExport(req []byte) ([]byte, error) {
	var r struct {
		Format string `json:"format"`
		Label  string `json:"label"`
		Root   string `json:"root"`
		Depth  int    `json:"depth"`
	}
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}

	issues, analyzer, stats := s.snapshot()
	if analyzer == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}

	format := export.GraphExportFormat(strings.ToLower(strings.TrimSpace(r.Format)))
	switch format {
	case "dot", "mermaid":
		// Kept as given.
	default:
		// Anything unrecognised falls back to JSON, as bv does.
		format = "json"
	}

	result, err := export.ExportGraph(issues, stats, export.GraphExportConfig{
		Format:   format,
		Label:    r.Label,
		Root:     r.Root,
		Depth:    r.Depth,
		DataHash: analyzer.DataHash(),
	})
	if err != nil {
		return nil, fmt.Errorf("exporting the graph: %w", err)
	}
	return json.Marshal(result)
}

// fileImpact rates the risk of touching a set of files.
func (s *Session) fileImpact(req []byte) ([]byte, error) {
	var r struct {
		Files []string `json:"files"`
		Limit int      `json:"limit"`
	}
	if len(req) == 0 {
		return nil, fmt.Errorf("file_impact requires \"files\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	if len(r.Files) == 0 {
		return nil, fmt.Errorf("file_impact requires a non-empty \"files\"")
	}

	result, err := s.correlationHistory(r.Limit, false)
	if err != nil {
		return nil, err
	}
	lookup := correlation.NewFileLookup(result.report)
	return json.Marshal(lookup.ImpactAnalysis(r.Files))
}
