package engine

import (
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// Sprints, burndown and capacity.
//
// `loader.LoadSprints` reads the sprint file; everything after it — the
// burndown maths, the capacity simulation — lives in `cmd/bv` and is
// reproduced here.

// workspaceRoot is the directory sprints are loaded relative to.
func (s *Session) workspaceRoot() string {
	return s.projectDir()
}

func (s *Session) loadSprints() ([]model.Sprint, error) {
	root := s.workspaceRoot()
	if root == "" {
		return nil, fmt.Errorf("session has no source")
	}
	sprints, err := loader.LoadSprints(root)
	if err != nil {
		return nil, err
	}
	if sprints == nil {
		sprints = []model.Sprint{}
	}
	return sprints, nil
}

func (s *Session) sprintList() ([]byte, error) {
	sprints, err := s.loadSprints()
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{
		"sprints":      sprints,
		"sprint_count": len(sprints),
	})
}

type sprintRequest struct {
	// ID names a sprint, or "current" for the active one.
	ID string `json:"id"`
	// Agents is how many workers the capacity simulation assumes.
	Agents int `json:"agents"`
	// Label narrows the capacity simulation to one label.
	Label string `json:"label"`
}

func decodeSprintRequest(req []byte) (sprintRequest, error) {
	var r sprintRequest
	if len(req) == 0 {
		return r, nil
	}
	err := json.Unmarshal(req, &r)
	return r, err
}

// resolveSprint finds a sprint by id, or the active one for "current".
func resolveSprint(sprints []model.Sprint, id string) (*model.Sprint, error) {
	if id == "" || id == "current" {
		for i := range sprints {
			if sprints[i].IsActive() {
				return &sprints[i], nil
			}
		}
		return nil, fmt.Errorf("no sprint is currently active")
	}
	for i := range sprints {
		if sprints[i].ID == id {
			return &sprints[i], nil
		}
	}
	return nil, fmt.Errorf("no sprint named %q", id)
}

func (s *Session) sprintShow(req []byte) ([]byte, error) {
	r, err := decodeSprintRequest(req)
	if err != nil {
		return nil, err
	}
	sprints, err := s.loadSprints()
	if err != nil {
		return nil, err
	}
	found, err := resolveSprint(sprints, r.ID)
	if err != nil {
		return nil, err
	}

	// The beads themselves travel with it, so the UI does not have to
	// re-resolve ids that may no longer exist.
	issues, _, _ := s.snapshot()
	byID := make(map[string]model.Issue, len(issues))
	for _, issue := range issues {
		byID[issue.ID] = issue
	}
	members := make([]model.Issue, 0, len(found.BeadIDs))
	missing := []string{}
	for _, id := range found.BeadIDs {
		if issue, ok := byID[id]; ok {
			members = append(members, issue)
		} else {
			// A sprint outliving one of its beads is worth reporting rather
			// than quietly shrinking the sprint.
			missing = append(missing, id)
		}
	}

	return json.Marshal(map[string]any{
		"sprint":  found,
		"issues":  members,
		"missing": missing,
		"active":  found.IsActive(),
	})
}

// burndown computes one sprint's burndown, ideal line and projection.
func (s *Session) burndown(req []byte) ([]byte, error) {
	r, err := decodeSprintRequest(req)
	if err != nil {
		return nil, err
	}
	sprints, err := s.loadSprints()
	if err != nil {
		return nil, err
	}
	sprint, err := resolveSprint(sprints, r.ID)
	if err != nil {
		return nil, err
	}

	issues, _, _ := s.snapshot()
	byID := make(map[string]model.Issue, len(issues))
	for _, issue := range issues {
		byID[issue.ID] = issue
	}

	members := make([]model.Issue, 0, len(sprint.BeadIDs))
	for _, id := range sprint.BeadIDs {
		if issue, ok := byID[id]; ok {
			members = append(members, issue)
		}
	}

	now := robotNow()
	total := len(members)
	completed := 0
	for _, issue := range members {
		if issue.Status == model.StatusClosed {
			completed++
		}
	}
	remaining := total - completed

	totalDays := int(sprint.EndDate.Sub(sprint.StartDate).Hours()/24) + 1
	elapsedDays, remainingDays := sprintProgress(sprint, now, totalDays)

	idealRate := 0.0
	if totalDays > 0 {
		idealRate = float64(total) / float64(totalDays)
	}
	actualRate := 0.0
	if elapsedDays > 0 {
		actualRate = float64(completed) / float64(elapsedDays)
	}

	projected, onTrack := project(sprint, now, remaining, completed, elapsedDays, actualRate)

	payload := map[string]any{
		"sprint_id":        sprint.ID,
		"sprint_name":      sprint.Name,
		"start_date":       sprint.StartDate,
		"end_date":         sprint.EndDate,
		"total_days":       totalDays,
		"elapsed_days":     elapsedDays,
		"remaining_days":   remainingDays,
		"total_issues":     total,
		"completed_issues": completed,
		"remaining_issues": remaining,
		"ideal_burn_rate":  idealRate,
		"actual_burn_rate": actualRate,
		"on_track":         onTrack,
		"daily_points":     dailyBurndown(members, sprint, now, total),
		"ideal_line":       idealLine(total, totalDays, sprint.StartDate),
	}
	// Absent rather than zero: with no progress there is no date to project,
	// and the epoch would read as a real prediction.
	if projected != nil {
		payload["projected_complete"] = projected
	}
	return json.Marshal(payload)
}

// sprintProgress reports days elapsed and remaining, clamped to the sprint.
func sprintProgress(sprint *model.Sprint, now time.Time, totalDays int) (int, int) {
	switch {
	case now.Before(sprint.StartDate):
		return 0, totalDays
	case now.After(sprint.EndDate):
		return totalDays, 0
	default:
		elapsed := int(now.Sub(sprint.StartDate).Hours()/24) + 1
		return elapsed, totalDays - elapsed
	}
}

// project estimates the completion date at the observed rate.
func project(
	sprint *model.Sprint, now time.Time, remaining, completed, elapsedDays int, rate float64,
) (*time.Time, bool) {
	if rate > 0 && remaining > 0 {
		date := now.AddDate(0, 0, int(float64(remaining)/rate)+1)
		return &date, !date.After(sprint.EndDate)
	}
	if remaining == 0 {
		return nil, true
	}
	if elapsedDays > 0 && completed == 0 {
		// Time has passed and nothing has closed: there is no rate to
		// extrapolate, and claiming "on track" would be the wrong default.
		return nil, false
	}
	return nil, true
}

// dailyBurndown walks the sprint day by day up to today.
func dailyBurndown(
	members []model.Issue, sprint *model.Sprint, now time.Time, total int,
) []model.BurndownPoint {
	points := []model.BurndownPoint{}
	for day := sprint.StartDate; !day.After(sprint.EndDate) && !day.After(now); day = day.AddDate(0, 0, 1) {
		// Inclusive end-of-day, so a bead closed at 23:30 counts that day.
		dayEnd := day.Add(24*time.Hour - time.Second)
		done := 0
		for _, issue := range members {
			if issue.ClosedAt != nil && !issue.ClosedAt.After(dayEnd) {
				done++
			}
		}
		points = append(points, model.BurndownPoint{
			Date:      day,
			Remaining: total - done,
			Completed: done,
		})
	}
	return points
}

// idealLine is the straight run from the full backlog down to zero.
func idealLine(total, totalDays int, start time.Time) []model.BurndownPoint {
	if total == 0 || totalDays <= 0 {
		// An empty sprint has no line to draw, and a flat zero would look
		// like a sprint that finished before it began.
		return []model.BurndownPoint{}
	}
	perDay := float64(total) / float64(totalDays)
	points := make([]model.BurndownPoint, 0, totalDays+1)
	for i := 0; i <= totalDays; i++ {
		remaining := total - int(float64(i)*perDay)
		if remaining < 0 {
			remaining = 0
		}
		points = append(points, model.BurndownPoint{
			Date:      start.AddDate(0, 0, i),
			Remaining: remaining,
			Completed: total - remaining,
		})
	}
	return points
}

// capacity simulates how long the open work takes with N agents.
//
// One deliberate divergence from bv: the dependency maps here are built from
// *blocking* edges only. bv's capacity handler walks every dependency type,
// so a parent-child link inflates its critical chain and therefore its serial
// time. This repository's rule is that only `blocks` and the empty type block,
// and applying it anywhere else while ignoring it here would be incoherent.
func (s *Session) capacity(req []byte) ([]byte, error) {
	r, err := decodeSprintRequest(req)
	if err != nil {
		return nil, err
	}
	agents := r.Agents
	if agents <= 0 {
		agents = 1
	}

	issues, _, _ := s.snapshot()
	stats := analysis.NewAnalyzer(issues).Analyze()

	targets := issues
	if r.Label != "" {
		filtered := make([]model.Issue, 0, len(issues))
		for _, issue := range issues {
			for _, label := range issue.Labels {
				if label == r.Label {
					filtered = append(filtered, issue)
					break
				}
			}
		}
		targets = filtered
	}

	open := make([]model.Issue, 0, len(targets))
	byID := make(map[string]model.Issue, len(targets))
	for _, issue := range targets {
		byID[issue.ID] = issue
		if issue.Status != model.StatusClosed && issue.Status != model.StatusTombstone {
			open = append(open, issue)
		}
	}

	minutes := map[string]int{}
	totalMinutes := 0
	now := robotNow()
	for _, issue := range open {
		estimate, err := analysis.EstimateETAForIssue(targets, &stats, issue.ID, 1, now)
		if err != nil {
			continue
		}
		minutes[issue.ID] = estimate.EstimatedMinutes
		totalMinutes += estimate.EstimatedMinutes
	}

	blocks, blockedBy := dependencyMaps(open, byID)

	actionable := []string{}
	for _, issue := range open {
		if len(blockedBy[issue.ID]) == 0 {
			actionable = append(actionable, issue.ID)
		}
	}
	sort.Strings(actionable)

	chain := longestChain(actionable, blocks, minutes)
	serialMinutes := 0
	for _, id := range chain {
		serialMinutes += minutes[id]
	}
	parallelMinutes := totalMinutes - serialMinutes
	if parallelMinutes < 0 {
		parallelMinutes = 0
	}

	parallelPct := 0.0
	if totalMinutes > 0 {
		parallelPct = float64(parallelMinutes) / float64(totalMinutes) * 100
	}
	effectiveMinutes := serialMinutes + parallelMinutes/agents

	return json.Marshal(map[string]any{
		"agents":               agents,
		"label":                r.Label,
		"open_issue_count":     len(open),
		"total_minutes":        totalMinutes,
		"total_days":           float64(totalMinutes) / (60 * 8),
		"serial_minutes":       serialMinutes,
		"parallel_minutes":     parallelMinutes,
		"parallelizable_pct":   parallelPct,
		"effective_minutes":    effectiveMinutes,
		"estimated_days":       float64(effectiveMinutes) / (60 * 8),
		"critical_path_length": len(chain),
		"critical_path":        chain,
		"actionable_count":     len(actionable),
		"actionable":           actionable,
		"bottlenecks":          bottlenecks(open, blocks),
	})
}

// dependencyMaps builds blocks/blocked-by over blocking edges only.
func dependencyMaps(
	open []model.Issue, byID map[string]model.Issue,
) (blocks map[string][]string, blockedBy map[string][]string) {
	blocks = map[string][]string{}
	blockedBy = map[string][]string{}
	present := map[string]bool{}
	for _, issue := range open {
		present[issue.ID] = true
	}

	for _, issue := range open {
		for _, dep := range issue.Dependencies {
			if dep == nil || !dep.Type.IsBlocking() {
				continue
			}
			// Only edges between beads still in scope: a closed blocker is
			// not holding anything up.
			if !present[dep.DependsOnID] {
				continue
			}
			blockedBy[issue.ID] = append(blockedBy[issue.ID], dep.DependsOnID)
			blocks[dep.DependsOnID] = append(blocks[dep.DependsOnID], issue.ID)
		}
	}
	return blocks, blockedBy
}

// longestChain finds the slowest dependent path, measured in minutes.
//
// bv picks the path with the most *steps*; measuring minutes instead answers
// the question capacity is actually asking, which is how long the work takes.
func longestChain(roots []string, blocks map[string][]string, minutes map[string]int) []string {
	var best []string
	bestCost := -1
	visiting := map[string]bool{}

	var walk func(id string, path []string, cost int)
	walk = func(id string, path []string, cost int) {
		// A cycle would otherwise recurse forever. The graph is not
		// guaranteed acyclic — detecting cycles is one of bv's features.
		if visiting[id] {
			return
		}
		visiting[id] = true
		defer func() { visiting[id] = false }()

		path = append(path, id)
		cost += minutes[id]

		// Every node is a candidate, not just a leaf. Recording only at
		// leaves loses the answer entirely when a cycle means no leaf is ever
		// reached — the walk unwinds having found nothing.
		if cost > bestCost {
			bestCost = cost
			best = append([]string(nil), path...)
		}

		for _, child := range blocks[id] {
			walk(child, path, cost)
		}
	}

	for _, root := range roots {
		walk(root, nil, 0)
	}
	if best == nil {
		best = []string{}
	}
	return best
}

// bottlenecks are the open beads holding up more than one other.
func bottlenecks(open []model.Issue, blocks map[string][]string) []map[string]any {
	type entry struct {
		id    string
		title string
		count int
		ids   []string
	}
	var found []entry
	for _, issue := range open {
		if len(blocks[issue.ID]) > 1 {
			found = append(found, entry{
				id: issue.ID, title: issue.Title,
				count: len(blocks[issue.ID]), ids: blocks[issue.ID],
			})
		}
	}
	sort.SliceStable(found, func(i, j int) bool {
		if found[i].count != found[j].count {
			return found[i].count > found[j].count
		}
		// Ties break on id so the list is reproducible.
		return found[i].id < found[j].id
	})
	if len(found) > 5 {
		found = found[:5]
	}

	out := make([]map[string]any, 0, len(found))
	for _, e := range found {
		out = append(out, map[string]any{
			"id": e.id, "title": e.title, "blocks_count": e.count, "blocks": e.ids,
		})
	}
	return out
}
