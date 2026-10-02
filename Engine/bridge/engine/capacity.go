package engine

import (
	"encoding/json"
	"sort"
	"strings"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// Capacity: how long the open work takes with N agents.
//
// Ported from bv v0.25.2's handleRobotCapacity and longestCapacityChain
// (cmd/bv/robot_registry.go), which are unexported. The per-bead estimate is
// bv's own analysis.EstimateETAForIssue and readiness is the analyzer's
// ReadinessIndex, both called rather than copied.
//
// bv takes two labels, and so does the request:
//
//   - `label` is the global --label scope (Session.view): the label's subgraph
//     is analysed, and only its core beads are candidates.
//   - `capacity_label` is --capacity-label, a filter over those candidates:
//     an exact, case-sensitive match on one of the bead's labels. A blank one
//     filters nothing.

type capacityRequest struct {
	Agents int `json:"agents"`
	scopeRequest
	CapacityLabel string `json:"capacity_label"`
}

// capacityBottleneck is bv's bottleneck row, field for field.
type capacityBottleneck struct {
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	BlocksCount int      `json:"blocks_count"`
	Blocks      []string `json:"blocks,omitempty"`
}

// capacityPayload is bv's output struct without its envelope. The omitempty
// tags are bv's: an empty selection carries no critical path, actionable list
// or bottlenecks, and an unfiltered run no label.
type capacityPayload struct {
	GeneratedAt       string               `json:"generated_at"`
	DataHash          string               `json:"data_hash"`
	Agents            int                  `json:"agents"`
	Label             string               `json:"label,omitempty"`
	OpenIssueCount    int                  `json:"open_issue_count"`
	TotalMinutes      int                  `json:"total_minutes"`
	TotalDays         float64              `json:"total_days"`
	SerialMinutes     int                  `json:"serial_minutes"`
	ParallelMinutes   int                  `json:"parallel_minutes"`
	ParallelizablePct float64              `json:"parallelizable_pct"`
	EstimatedDays     float64              `json:"estimated_days"`
	CriticalPathLen   int                  `json:"critical_path_length"`
	CriticalPath      []string             `json:"critical_path,omitempty"`
	ActionableCount   int                  `json:"actionable_count"`
	Actionable        []string             `json:"actionable,omitempty"`
	Bottlenecks       []capacityBottleneck `json:"bottlenecks,omitempty"`
}

func (s *Session) capacity(req []byte) ([]byte, error) {
	var r capacityRequest
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}
	agents := 1
	if r.Agents > 0 {
		agents = r.Agents
	}
	filter := ""
	if strings.TrimSpace(r.CapacityLabel) != "" {
		filter = r.CapacityLabel
	}

	v, err := s.view(r.scopeRequest)
	if err != nil {
		return nil, err
	}
	// bv runs the full analysis here whatever else is configured, because the
	// estimate's depth factor reads the critical-path score, a Phase-2
	// metric. A session that skips Phase 2 has none, so it analyses afresh
	// rather than estimating every bead as if it had no depth.
	stats := v.stats
	if s.config.SkipPhase2 {
		full := analysis.NewAnalyzer(v.issues).Analyze()
		stats = &full
	} else if stats != nil {
		stats.WaitForPhase2()
	}

	release := s.pinClock(v.analyzer)
	defer release()
	now := v.analyzer.Now()

	targets := make([]model.Issue, 0, len(v.issues))
	for _, issue := range v.issues {
		if !v.analyzer.IsCandidate(issue.ID) {
			continue
		}
		if filter != "" && !hasLabel(issue, filter) {
			continue
		}
		targets = append(targets, issue)
	}
	sort.Slice(targets, func(i, j int) bool { return targets[i].ID < targets[j].ID })

	open := make([]model.Issue, 0, len(targets))
	inScope := make(map[string]bool, len(targets))
	for _, issue := range targets {
		if !issue.Status.IsClosed() && !issue.Status.IsTombstone() {
			inScope[issue.ID] = true
			open = append(open, issue)
		}
	}

	estimate := func(id string) int {
		eta, err := analysis.EstimateETAForIssue(targets, stats, id, 1, now)
		if err != nil {
			return 0
		}
		return eta.EstimatedMinutes
	}
	totalMinutes := 0
	for _, issue := range open {
		totalMinutes += estimate(issue.ID)
	}

	// Readiness keeps the full-source gates; the chain uses only distinct
	// blocking edges between open beads in the selection.
	blocks := map[string][]string{}
	for _, issue := range open {
		seen := map[string]bool{}
		for _, dep := range issue.Dependencies {
			if dep == nil || !dep.Type.IsBlocking() || seen[dep.DependsOnID] {
				continue
			}
			if inScope[dep.DependsOnID] {
				seen[dep.DependsOnID] = true
				blocks[dep.DependsOnID] = append(blocks[dep.DependsOnID], issue.ID)
			}
		}
	}

	readiness := v.analyzer.Readiness()
	actionable := []string{}
	for _, issue := range open {
		if readiness.Ready(issue.ID, now) {
			actionable = append(actionable, issue.ID)
		}
	}

	chain := longestCapacityChain(actionable, blocks)
	serialMinutes := 0
	for _, id := range chain {
		serialMinutes += estimate(id)
	}
	parallelMinutes := totalMinutes - serialMinutes
	parallelPct := 0.0
	if totalMinutes > 0 {
		parallelPct = float64(parallelMinutes) / float64(totalMinutes) * 100
	}
	effectiveMinutes := serialMinutes + parallelMinutes/agents

	bottlenecks := []capacityBottleneck{}
	for _, issue := range open {
		if len(blocks[issue.ID]) > 1 {
			bottlenecks = append(bottlenecks, capacityBottleneck{
				ID: issue.ID, Title: issue.Title,
				BlocksCount: len(blocks[issue.ID]), Blocks: blocks[issue.ID],
			})
		}
	}
	sort.Slice(bottlenecks, func(i, j int) bool {
		if bottlenecks[i].BlocksCount == bottlenecks[j].BlocksCount {
			return bottlenecks[i].ID < bottlenecks[j].ID
		}
		return bottlenecks[i].BlocksCount > bottlenecks[j].BlocksCount
	})
	if len(bottlenecks) > 5 {
		bottlenecks = bottlenecks[:5]
	}

	// bv hashes the issues it analysed — the label's subgraph when scoped —
	// not the session's, so this envelope's data_hash follows the scope.
	generated, _ := s.robotEnvelope()
	hash := analysis.ComputeDataHash(v.issues)
	payload := capacityPayload{
		GeneratedAt:       generated,
		DataHash:          hash,
		Agents:            agents,
		Label:             filter,
		OpenIssueCount:    len(open),
		TotalMinutes:      totalMinutes,
		TotalDays:         float64(totalMinutes) / (60.0 * 8.0),
		SerialMinutes:     serialMinutes,
		ParallelMinutes:   parallelMinutes,
		ParallelizablePct: parallelPct,
		EstimatedDays:     float64(effectiveMinutes) / (60.0 * 8.0),
		CriticalPathLen:   len(chain),
		CriticalPath:      chain,
		ActionableCount:   len(actionable),
		Actionable:        actionable,
		Bottlenecks:       bottlenecks,
	}
	return s.withProvenance(payload, hash, v.scope)
}

// hasLabel is --capacity-label's match: exact and case-sensitive.
func hasLabel(issue model.Issue, label string) bool {
	for _, l := range issue.Labels {
		if l == label {
			return true
		}
	}
	return false
}

// longestCapacityChain is bv v0.25.2's longestCapacityChain
// (cmd/bv/robot_registry.go), unexported there. It measures the chain in
// steps, not minutes, and keeps the first longest path in seed and
// neighbour order. An acyclic reachable graph shares suffix lengths; a
// reachable cycle falls back to an exhaustive simple-path walk.
func longestCapacityChain(starts []string, blocks map[string][]string) []string {
	if len(starts) == 0 {
		return nil
	}
	state := make(map[string]uint8)
	var postorder []string
	hasCycle := false
	var visit func(string)
	visit = func(id string) {
		if state[id] == 1 {
			hasCycle = true
			return
		}
		if state[id] == 2 {
			return
		}
		state[id] = 1
		for _, nextID := range blocks[id] {
			visit(nextID)
		}
		state[id] = 2
		postorder = append(postorder, id)
	}
	for _, id := range starts {
		visit(id)
	}
	if !hasCycle {
		length := make(map[string]int, len(postorder))
		next := make(map[string]string, len(postorder))
		for _, id := range postorder {
			length[id] = 1
			for _, nextID := range blocks[id] {
				if candidate := 1 + length[nextID]; candidate > length[id] {
					length[id] = candidate
					next[id] = nextID
				}
			}
		}
		start := starts[0]
		for _, id := range starts[1:] {
			if length[id] > length[start] {
				start = id
			}
		}
		path := make([]string, 0, length[start])
		for id, remaining := start, length[start]; remaining > 0; id, remaining = next[id], remaining-1 {
			path = append(path, id)
		}
		return path
	}

	var longest []string
	visited := make(map[string]bool)
	var dfs func(string, []string)
	dfs = func(id string, path []string) {
		if visited[id] {
			return
		}
		visited[id] = true
		path = append(path, id)
		if len(path) > len(longest) {
			longest = append([]string(nil), path...)
		}
		for _, nextID := range blocks[id] {
			dfs(nextID, path)
		}
		visited[id] = false
	}
	for _, id := range starts {
		dfs(id, nil)
	}
	return longest
}
