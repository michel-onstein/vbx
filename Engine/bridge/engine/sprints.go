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
// Ported from bv v0.25.2. `loader.LoadSprints` reads the sprint file and
// `analysis.DetectAtRisk` flags at-risk sprint beads; both are bv's own,
// called rather than copied. Everything else — the burndown maths
// (`calculateBurndownAt`, `generateDailyBurndown`, `generateIdealLine`,
// `generateIdealLineScoped`), the scope-change walk
// (`computeSprintScopeChanges`, see sprint_scope.go) and the capacity
// simulation — is still unexported in v0.25.2's `cmd/bv` (main.go and
// robot_registry.go) and is reproduced here.

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

// burndown computes one sprint's burndown, ideal line, projection, scope
// changes and at-risk beads — bv's `--robot-burndown`.
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
	now := robotNow()
	payload, total := burndownPayload(sprint, issues, now)

	// Scope changes come from the sprint file's git history. As in bv, a
	// workspace that is not itself a repository root has none, and an
	// unreadable history is not a reason to fail the burndown.
	byID := make(map[string]model.Issue, len(issues))
	for _, issue := range issues {
		byID[issue.ID] = issue
	}
	if changes, err := sprintScopeChanges(s.workspaceRoot(), sprint, byID, now); err == nil && len(changes) > 0 {
		payload["scope_changes"] = changes
		payload["ideal_line"] = idealLineScoped(sprint, total, changes)
	}

	// bv inlines the burndown under its robot envelope, so vbx does too.
	generated, hash := s.robotEnvelope()
	payload["generated_at"] = generated
	payload["data_hash"] = hash
	return s.withProvenance(payload, hash, provenanceScope{})
}

// burndownPayload is bv's calculateBurndownAt: everything except the scope
// changes, which need the repository. It returns the sprint's bead count too,
// which the scope-aware ideal line starts from.
func burndownPayload(sprint *model.Sprint, issues []model.Issue, now time.Time) (map[string]any, int) {
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

	total := len(members)
	completed := 0
	for _, issue := range members {
		if issue.Status == model.StatusClosed {
			completed++
		}
	}
	remaining := total - completed

	// A sprint without both dates has no days to count, rather than the
	// nonsense span between the zero time and a real date.
	totalDays, elapsedDays, remainingDays := 0, 0, 0
	if !sprint.StartDate.IsZero() && !sprint.EndDate.IsZero() {
		totalDays = sprintDays(sprint)
		elapsedDays, remainingDays = sprintProgress(sprint, now, totalDays)
	}

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
		"ideal_line":       idealLine(sprint, total),
		// bv's own detector, over the whole bead set so a blocker outside the
		// sprint still counts. Always present: an empty list is a real answer
		// — nothing is at risk — not a missing one.
		"at_risk": analysis.DetectAtRisk(issues, sprint, now, analysis.DefaultAtRiskThresholds()),
	}
	// Absent rather than zero: with no progress there is no date to project,
	// and the epoch would read as a real prediction.
	if projected != nil {
		payload["projected_complete"] = projected
	}
	return payload, total
}

// sprintDays is the sprint's length in days, both ends inclusive.
func sprintDays(sprint *model.Sprint) int {
	return int(sprint.EndDate.Sub(sprint.StartDate).Hours()/24) + 1
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
	if sprint.StartDate.IsZero() || sprint.EndDate.IsZero() {
		return points
	}
	for day := sprint.StartDate; !day.After(sprint.EndDate) && !day.After(now); day = day.AddDate(0, 0, 1) {
		// Inclusive end-of-day, so a bead closed at 23:30 counts that day.
		dayEnd := day.Add(24*time.Hour - time.Second)
		done := 0
		for _, issue := range members {
			// Closed now *and* closed by then: a reopened bead keeps a stale
			// closed_at, and counting it would burn down work still open.
			if issue.Status == model.StatusClosed && issue.ClosedAt != nil && !issue.ClosedAt.After(dayEnd) {
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
func idealLine(sprint *model.Sprint, total int) []model.BurndownPoint {
	if total == 0 {
		// An empty sprint has no line to draw, and a flat zero would look
		// like a sprint that finished before it began.
		return []model.BurndownPoint{}
	}
	return idealLineScoped(sprint, total, nil)
}

// idealLineScoped is bv's generateIdealLineScoped: the ideal line made
// scope-aware. At each scope-change date the remaining count moves by the
// beads added or removed, and the trajectory re-linearises from that day's
// remaining count to zero at the sprint end — so a mid-sprint addition shows
// as a change of slope rather than as a misleading "behind schedule" gap.
// Without events it is the plain straight line, exactly as bv draws it.
func idealLineScoped(sprint *model.Sprint, total int, events []scopeChange) []model.BurndownPoint {
	points := []model.BurndownPoint{}
	if sprint.StartDate.IsZero() || sprint.EndDate.IsZero() {
		return points
	}
	totalDays := sprintDays(sprint)
	if totalDays <= 0 {
		return points
	}
	dayOf := func(t time.Time) int {
		return int(t.Sub(sprint.StartDate).Hours() / 24)
	}
	// Net scope change per sprint day. A change on or before the first day
	// is part of the starting scope; one after the end is not part of the
	// plan at all.
	delta := map[int]int{}
	initial := total
	for _, event := range events {
		change := 0
		switch event.Action {
		case scopeAdded:
			change = 1
		case scopeRemoved:
			change = -1
		}
		day := dayOf(event.Date)
		if day <= 0 || day > totalDays {
			continue
		}
		delta[day] += change
		initial -= change
	}
	if initial < 0 {
		initial = 0
	}

	// Each segment burns linearly from segRemaining at segStart to zero at
	// the sprint end, with the same truncating arithmetic as the plain line,
	// so a sprint whose events all fall outside the window draws the
	// identical line.
	segStart, segRemaining := 0, initial
	idealAt := func(day int) int {
		daysLeft := totalDays - segStart
		if daysLeft <= 0 {
			return segRemaining
		}
		perDay := float64(segRemaining) / float64(daysLeft)
		remaining := segRemaining - int(float64(day-segStart)*perDay)
		if remaining < 0 {
			remaining = 0
		}
		return remaining
	}
	for i := 0; i <= totalDays; i++ {
		if d, ok := delta[i]; ok && d != 0 && i > 0 {
			segRemaining = idealAt(i) + d
			if segRemaining < 0 {
				segRemaining = 0
			}
			segStart = i
		}
		remaining := idealAt(i)
		points = append(points, model.BurndownPoint{
			Date:      sprint.StartDate.AddDate(0, 0, i),
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
