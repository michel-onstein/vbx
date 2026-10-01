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
		Label         string  `json:"label"`
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

	// Suggestions are drawn from the label's subgraph under a label, and
	// stamped with the unscoped data hash, as bv's are.
	v := s.view(r.Label)
	_, hash := s.robotEnvelope()
	return s.withProvenance(
		analysis.GenerateRobotSuggestOutput(v.issues, config, hash), hash, v.scope)
}

// priority ranks beads whose priority looks wrong, with the reasoning.
func (s *Session) priority(req []byte) ([]byte, error) {
	var r struct {
		MinConfidence float64 `json:"min_confidence"`
		MaxResults    int     `json:"max_results"`
		ByLabel       string  `json:"by_label"`
		ByAssignee    string  `json:"by_assignee"`
		// Label is bv's global --label scope (scope.go), not ByLabel's filter:
		// it changes the graph the recommendations are computed over.
		Label string `json:"label"`
	}
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}

	v := s.view(r.Label)
	issues, analyzer, stats := v.issues, v.analyzer, v.stats
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
	// Allocated, never recommendations[:0]: with nothing to recommend that
	// slice is nil and encodes as null, where bv writes [].
	filtered := make([]analysis.EnhancedPriorityRecommendation, 0, len(recommendations))
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

	return s.withProvenance(map[string]any{
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
	}, hash, v.scope)
}

func containsExact(values []string, needle string) bool {
	for _, value := range values {
		if value == needle {
			return true
		}
	}
	return false
}

// nextDegradation is one reason robot-next answered without a claim.
type nextDegradation struct {
	Code     string `json:"code"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
	Repair   string `json:"repair,omitempty"`
}

// nextDiagnosticPick is the top pick robot-next declined, for inspection.
type nextDiagnosticPick struct {
	ID       string   `json:"id"`
	Title    string   `json:"title"`
	Score    float64  `json:"score"`
	Reasons  []string `json:"reasons"`
	Unblocks int      `json:"unblocks"`
}

// nextOutput is bv 0.25's robot-next payload, field for field, under vbx's
// envelope; next() adds the provenance vbx ports (provenance.go, ADR-023).
type nextOutput struct {
	GeneratedAt       string                `json:"generated_at"`
	DataHash          string                `json:"data_hash"`
	Actionable        bool                  `json:"actionable"`
	Phase2Ready       bool                  `json:"phase2_ready"`
	Status            analysis.MetricStatus `json:"status"`
	Message           string                `json:"message,omitempty"`
	ID                string                `json:"id,omitempty"`
	Title             string                `json:"title,omitempty"`
	Score             float64               `json:"score,omitempty"`
	Reasons           []string              `json:"reasons,omitempty"`
	Unblocks          int                   `json:"unblocks,omitempty"`
	DiagnosticTopPick *nextDiagnosticPick   `json:"diagnostic_top_pick,omitempty"`
	ClaimCmd          string                `json:"claim_command,omitempty"`
	ShowCmd           string                `json:"show_command,omitempty"`
	Actions           *model.IssueActions   `json:"actions,omitempty"`
	Degraded          []nextDegradation     `json:"degraded,omitempty"`
	UsageHints        []string              `json:"usage_hints,omitempty"`
}

func diagnosticFromPick(pick analysis.TopPick) *nextDiagnosticPick {
	return &nextDiagnosticPick{
		ID: pick.ID, Title: pick.Title, Score: pick.Score,
		Reasons: pick.Reasons, Unblocks: pick.Unblocks,
	}
}

// next returns the single bead that is safe to claim, with the command that
// claims it.
//
// This is `cmd/bv`'s handleRobotNext, which cannot be imported. Its gates run
// in bv's order, and each one that fails names itself in `degraded` with the
// pick it declined, because the repair differs:
//
//  1. the load is partial (source_authority_incomplete);
//  2. triage has no top pick at all (no_actionable_recommendation);
//  3. no top pick passes the claim gate (robot_next_claim_unsafe);
//  4. the metrics the score depends on are incomplete
//     (robot_next_metric_incomplete);
//  5. the bead has no live tracker route (live_action_route_unavailable) —
//     always the outcome in the app, which never resolves one (ADR-020).
//
// The claim command is the tracker's own `br update --claim`, from the bead's
// origin, never a string assembled here: bv 0.25 replaced the old
// `--status=in_progress` form with the atomic claim, and only a bead whose
// tracker advertises it gets one.
//
// A `label` in the request picks from the label's subgraph (scope.go), and
// only a labelled bead can be the pick.
func (s *Session) next(req []byte) ([]byte, error) {
	label, err := labelRequest(req)
	if err != nil {
		return nil, err
	}
	v := s.view(label)
	issues, stats := v.issues, v.stats
	if stats != nil {
		stats.WaitForPhase2()
	}

	now := robotNow()
	// The full-source authority, not one rebuilt from the visible set: a
	// tombstoned blocker is resolved, and without its record it would read
	// as missing and withhold its dependents.
	readiness := s.readinessIndex()
	opts := analysis.TriageOptions{
		WaitForPhase2: true,
		Readiness:     readiness,
		CandidateIDs:  v.candidates,
		UseFastConfig: true,
		SeedDataHash:  v.seedHash(),
	}
	triage := analysis.ComputeTriageWithOptionsAndTime(issues, opts, now)

	generated, hash := s.robotEnvelope()
	output := nextOutput{
		GeneratedAt: generated,
		DataHash:    hash,
		Phase2Ready: triage.Meta.Phase2Ready,
		Status:      triage.Status,
		UsageHints: []string{
			"Use scripts/br_retry.sh actionable --json plus the claim gate before mutating Beads state in crowded swarms.",
			"No claim_command is emitted unless the item is open, unblocked, unassigned, and triage metrics are ready.",
			"Inspect .status for skipped, timeout, or pending graph phases.",
		},
	}
	picks := triage.QuickRef.TopPicks

	if !s.claimsProven() {
		output.Message = "No claim command emitted because source authority is incomplete or stale"
		if len(picks) > 0 {
			output.DiagnosticTopPick = diagnosticFromPick(picks[0])
		}
		output.Degraded = []nextDegradation{{
			Code: "source_authority_incomplete", Severity: "warning",
			Message: "Readiness is provisional; inspect source_authority for failed sources, dropped records, or stale fallback.",
			Repair:  "Restore or refresh the affected sources and rerun the command before claiming work.",
		}}
		return s.withProvenance(output, hash, v.scope)
	}

	if len(picks) == 0 {
		output.Message = "No proven actionable item available"
		output.Degraded = []nextDegradation{{
			Code:     "no_actionable_recommendation",
			Severity: "info",
			Message:  "No open, unblocked, unassigned non-epic recommendation passed the robot-next claimability filter.",
			Repair:   "Use br ready --json or scripts/br_retry.sh actionable --json for authoritative claim candidates.",
		}}
		return s.withProvenance(output, hash, v.scope)
	}

	byID := make(map[string]model.Issue, len(issues))
	for _, issue := range issues {
		byID[issue.ID] = issue
	}

	diagnostic := diagnosticFromPick(picks[0])
	var top *analysis.TopPick
	var unsafeReasons []string
	for i := range picks {
		reasons := claimabilityReasons(picks[i].ID, byID, readiness, now)
		if len(reasons) == 0 {
			top = &picks[i]
			break
		}
		if len(unsafeReasons) == 0 {
			unsafeReasons = reasons
		}
	}
	if top == nil {
		output.Message = "No claim command emitted because the top recommendation was not claim-safe"
		output.DiagnosticTopPick = diagnostic
		output.Degraded = []nextDegradation{{
			Code:     "robot_next_claim_unsafe",
			Severity: "warning",
			Message:  strings.Join(unsafeReasons, "; "),
			Repair:   "Use the authoritative Beads actionable queue plus claim gate before claiming work.",
		}}
		return s.withProvenance(output, hash, v.scope)
	}

	if reasons := triage.Status.ClaimUnsafeReasons(); len(reasons) > 0 {
		output.Message = "No claim command emitted because triage metrics were incomplete"
		output.DiagnosticTopPick = diagnostic
		output.Degraded = []nextDegradation{{
			Code:     "robot_next_metric_incomplete",
			Severity: "warning",
			Message:  strings.Join(reasons, "; "),
			Repair:   "Retry bv --robot-next after graph metrics are available, or use the authoritative Beads actionable queue plus claim gate.",
		}}
		return s.withProvenance(output, hash, v.scope)
	}

	actions := byID[top.ID].Actions(true)
	output.Actions = &actions
	if actions.Show != nil {
		output.ShowCmd = actions.Show.Shell
	}
	if actions.Claim == nil {
		output.Message = "No claim command emitted: " + actions.UnavailableReason
		output.DiagnosticTopPick = diagnostic
		output.Degraded = []nextDegradation{{
			Code: "live_action_route_unavailable", Severity: "info",
			Message: actions.UnavailableReason,
		}}
		return s.withProvenance(output, hash, v.scope)
	}

	output.Actionable = true
	output.ID = top.ID
	output.Title = top.Title
	output.Score = top.Score
	output.Reasons = top.Reasons
	output.Unblocks = top.Unblocks
	output.ClaimCmd = actions.Claim.Shell
	return s.withProvenance(output, hash, v.scope)
}

// claimabilityReasons lists why a bead cannot be claimed, in bv's order — an
// empty list means it can.
func claimabilityReasons(
	id string, byID map[string]model.Issue, readiness *model.ReadinessIndex, now time.Time,
) []string {
	issue, known := byID[id]
	if !known {
		return []string{fmt.Sprintf("%s is absent from loaded Beads records", id)}
	}

	var reasons []string
	if !strings.EqualFold(strings.TrimSpace(string(issue.Status)), string(model.StatusOpen)) {
		reasons = append(reasons, fmt.Sprintf("%s status is %q", id, issue.Status))
	}
	if strings.EqualFold(strings.TrimSpace(string(issue.IssueType)), string(model.TypeEpic)) {
		reasons = append(reasons, fmt.Sprintf("%s is an epic", id))
	}
	if assignee := strings.TrimSpace(issue.Assignee); assignee != "" {
		reasons = append(reasons, fmt.Sprintf("%s is already assigned to %s", id, assignee))
	}
	// A future defer_until withholds the bead, exactly as `br ready` hides it.
	if issue.IsDeferredAt(now) {
		reasons = append(reasons, fmt.Sprintf("%s is deferred until %s",
			id, issue.DeferUntil.UTC().Format(time.RFC3339)))
	}
	if blockers := readiness.Blockers(issue.ID); len(blockers) > 0 {
		reasons = append(reasons,
			fmt.Sprintf("%s is blocked by %s", id, strings.Join(blockers, ", ")))
	}
	if readiness.DependencyState(issue.ID) == model.DependenciesUnknown {
		reasons = append(reasons, "dependency authority is missing or unresolved")
	}
	if readiness.HasOpenChildren(issue.ID) {
		reasons = append(reasons, "parent still has open children")
	}
	return reasons
}

// insights reports the deep graph metrics.
func (s *Session) insights(req []byte) ([]byte, error) {
	var r struct {
		Limit int    `json:"limit"`
		Label string `json:"label"`
	}
	if len(req) > 0 {
		_ = json.Unmarshal(req, &r)
	}
	limit := r.Limit
	if limit <= 0 {
		limit = 200
	}

	// Under a label the metrics are the label subgraph's, analysed afresh.
	v := s.view(r.Label)
	analyzer, stats := v.analyzer, v.stats
	if analyzer == nil || stats == nil {
		return nil, fmt.Errorf("session has no analysis")
	}
	stats.WaitForPhase2()

	generated, hash := s.robotEnvelope()
	return s.withProvenance(map[string]any{
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
	}, hash, v.scope)
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

// limitSlice keeps the first limit values. A graph with no articulation
// points stays null rather than becoming [], because bv's insights writes it
// that way — the empty selection of an unknown label is where it shows.
func limitSlice(values []string, limit int) []string {
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

	// The label is a scope (scope.go), never passed to the exporter: the view
	// already selected the label subgraph, and ExportGraph's own label filter
	// keeps only the labelled beads, which erases their dependency context.
	v := s.view(r.Label)
	if v.analyzer == nil {
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

	dataHash := v.dataHash
	result, err := export.ExportGraph(v.issues, v.stats, export.GraphExportConfig{
		Format:   format,
		Root:     r.Root,
		Depth:    r.Depth,
		DataHash: dataHash,
	})
	if err != nil {
		return nil, fmt.Errorf("exporting the graph: %w", err)
	}
	if r.Label != "" {
		if result.FiltersApplied == nil {
			result.FiltersApplied = make(map[string]string)
		}
		result.FiltersApplied["label"] = r.Label
	}
	// bv writes data_hash from its envelope, so it is there even when the
	// exporter returns an empty graph — an unknown label — and leaves it unset.
	result.DataHash = dataHash
	return s.withProvenance(result, dataHash, v.scope)
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
