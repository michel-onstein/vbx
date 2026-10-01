package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/correlation"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// historyRequest is the shared shape of the correlation methods' arguments.
type historyRequest struct {
	// ID names a bead, for the methods scoped to one.
	ID string `json:"id"`
	// Path names a file, for the file-centric methods.
	Path string `json:"path"`
	// Limit caps commits walked, or rows returned, depending on the method.
	Limit int `json:"limit"`
	// Depth bounds the impact network's expansion around a bead.
	Depth int `json:"depth"`
	// Threshold is the minimum co-change correlation for file relations.
	Threshold float64 `json:"threshold"`
	// Refresh discards the cached report and walks the history again.
	Refresh bool `json:"refresh"`
}

func decodeHistoryRequest(req []byte) (historyRequest, error) {
	var r historyRequest
	if len(req) == 0 {
		return r, nil
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return r, err
	}
	return r, nil
}

// correlationHistory returns the session's history report, walking the object
// store on first use and caching the result.
//
// The walk decodes blob content, so it is far too expensive to repeat per
// request. It is invalidated when the workspace reloads, since a changed bead
// set changes every attribution.
func (s *Session) correlationHistory(limit int, refresh bool) (*historyResult, error) {
	s.historyMu.Lock()
	defer s.historyMu.Unlock()

	if s.history != nil && !refresh && limit == s.historyLimit {
		return s.history, nil
	}

	s.mu.RLock()
	source, issues := s.source, s.records
	s.mu.RUnlock()
	if source == "" {
		return nil, fmt.Errorf("session has no source")
	}

	extractor, err := openObjectStore(source, issues)
	if err != nil {
		return nil, err
	}
	result, err := extractor.extract(
		context.Background(), correlation.CorrelatorOptions{Limit: limit})
	if err != nil {
		return nil, err
	}

	// Feedback is applied after extraction rather than during it, so that a
	// confirm or reject can be re-applied without re-walking the history.
	if store, err := s.feedbackStore(); err == nil {
		applyFeedback(result.report, store)
	}

	s.history, s.historyLimit = result, limit
	return result, nil
}

// feedbackStore opens the workspace's correlation feedback sidecar.
func (s *Session) feedbackStore() (*correlation.FeedbackStore, error) {
	s.mu.RLock()
	source := s.source
	s.mu.RUnlock()
	if source == "" {
		return nil, fmt.Errorf("session has no source")
	}
	store := correlation.NewFeedbackStore(filepath.Dir(source))
	if err := store.Load(); err != nil {
		return nil, err
	}
	return store, nil
}

// applyFeedback folds a human verdict into the report's confidences.
//
// A rejected link is removed outright rather than merely downweighted: the
// point of rejecting it is that it is wrong, and leaving it at low confidence
// would keep it in every count and every file index. A confirmed link is
// raised to the top of bv's band for its method — not past it, because the
// band is what the method's confidence means.
func applyFeedback(report *correlation.HistoryReport, store *correlation.FeedbackStore) {
	for id, history := range report.Histories {
		kept := history.Commits[:0]
		for _, commit := range history.Commits {
			verdict, found := store.Get(commit.SHA, id)
			if !found {
				kept = append(kept, commit)
				continue
			}
			switch verdict.Type {
			case correlation.FeedbackReject:
				continue
			case correlation.FeedbackConfirm:
				if band, ok := correlation.MethodRanges[commit.Method]; ok {
					commit.Confidence = band.Max
				} else {
					commit.Confidence = 1
				}
				commit.Reason = "confirmed: " + verdict.Reason
			}
			kept = append(kept, commit)
		}
		history.Commits = kept
		report.Histories[id] = history
	}

	// The commit index is derived, so it has to be rebuilt rather than
	// patched — a rejected link that stays in the index would keep the commit
	// out of the orphan list while belonging to no bead.
	rebuilt := correlation.CommitIndex{}
	withCommits := 0
	for id, history := range report.Histories {
		if len(history.Commits) > 0 {
			withCommits++
		}
		for _, commit := range history.Commits {
			rebuilt[commit.SHA] = appendUnique(rebuilt[commit.SHA], id)
		}
	}
	report.CommitIndex = rebuilt
	report.Stats.BeadsWithCommits = withCommits
}

// feedbackRequest is a verdict on one commit-to-bead link.
type feedbackRequest struct {
	SHA    string `json:"sha"`
	BeadID string `json:"bead_id"`
	By     string `json:"by"`
	Reason string `json:"reason"`
}

// correlationFeedback returns every recorded verdict and the accuracy stats.
func (s *Session) correlationFeedback() ([]byte, error) {
	store, err := s.feedbackStore()
	if err != nil {
		return nil, err
	}
	all := store.GetAll()
	if all == nil {
		all = []correlation.CorrelationFeedback{}
	}
	return json.Marshal(map[string]any{
		"feedback": all,
		"stats":    store.GetStats(),
	})
}

// recordFeedback confirms or rejects one link.
func (s *Session) recordFeedback(req []byte, verdict correlation.FeedbackType) ([]byte, error) {
	var r feedbackRequest
	if len(req) == 0 {
		return nil, fmt.Errorf("feedback requires \"sha\" and \"bead_id\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	if r.SHA == "" || r.BeadID == "" {
		return nil, fmt.Errorf("feedback requires a non-empty \"sha\" and \"bead_id\"")
	}
	if r.By == "" {
		r.By = "vbx"
	}

	store, err := s.feedbackStore()
	if err != nil {
		return nil, err
	}

	// The original confidence is recorded alongside the verdict, so the
	// accuracy stats can say what the engine believed at the time.
	original := s.confidenceOf(r.SHA, r.BeadID)

	switch verdict {
	case correlation.FeedbackReject:
		err = store.Reject(r.SHA, r.BeadID, r.By, original, r.Reason)
	default:
		err = store.Confirm(r.SHA, r.BeadID, r.By, original, r.Reason)
	}
	if err != nil {
		return nil, err
	}

	// Re-apply against the cached report so the change is visible without
	// paying for another walk.
	s.historyMu.Lock()
	if s.history != nil {
		applyFeedback(s.history.report, store)
	}
	s.historyMu.Unlock()

	return json.Marshal(map[string]any{
		"sha":           r.SHA,
		"bead_id":       r.BeadID,
		"type":          string(verdict),
		"by":            r.By,
		"reason":        r.Reason,
		"original_conf": original,
		"stats":         store.GetStats(),
	})
}

// confidenceOf finds what the engine currently believes about one link.
func (s *Session) confidenceOf(sha, beadID string) float64 {
	s.historyMu.Lock()
	defer s.historyMu.Unlock()
	if s.history == nil {
		return 0
	}
	for _, commit := range s.history.report.Histories[beadID].Commits {
		if commit.SHA == sha {
			return commit.Confidence
		}
	}
	return 0
}

// invalidateHistory drops the cached report. Called whenever the bead set
// changes, because every attribution is computed against it.
func (s *Session) invalidateHistory() {
	s.historyMu.Lock()
	s.history, s.historyLimit = nil, 0
	s.historyMu.Unlock()
}

func (s *Session) historyPayload(req []byte) ([]byte, error) {
	r, err := decodeHistoryRequest(req)
	if err != nil {
		return nil, err
	}
	result, err := s.correlationHistory(r.Limit, r.Refresh)
	if err != nil {
		return nil, err
	}

	if r.ID == "" {
		return json.Marshal(result.report)
	}
	history, ok := result.report.Histories[r.ID]
	if !ok {
		return nil, fmt.Errorf("no history for %q", r.ID)
	}
	return json.Marshal(map[string]any{
		"generated_at": result.report.GeneratedAt,
		"data_hash":    result.report.DataHash,
		"git_range":    result.report.GitRange,
		"history":      history,
	})
}

// causality returns one bead's causal chain and the insights drawn from it.
func (s *Session) causality(req []byte) ([]byte, error) {
	r, err := decodeHistoryRequest(req)
	if err != nil {
		return nil, err
	}
	if r.ID == "" {
		return nil, fmt.Errorf("causality requires an \"id\"")
	}
	result, err := s.correlationHistory(r.Limit, r.Refresh)
	if err != nil {
		return nil, err
	}

	issues := s.recordSet() // the history covers every record
	opts := correlation.DefaultCausalityOptions()
	// Blocker titles turn "waiting on vbx-8ou" into a sentence naming the
	// bead, which is the difference between a chain you can read and a list
	// of identifiers.
	opts.BlockerTitles = titlesByID(issues)

	chain := result.report.BuildCausalityChain(r.ID, opts)
	if chain == nil {
		return nil, fmt.Errorf("no history for %q", r.ID)
	}
	return json.Marshal(chain)
}

// relatedWork finds beads that touched the same files, commits or window.
func (s *Session) relatedWork(req []byte) ([]byte, error) {
	r, err := decodeHistoryRequest(req)
	if err != nil {
		return nil, err
	}
	if r.ID == "" {
		return nil, fmt.Errorf("related requires an \"id\"")
	}
	result, err := s.correlationHistory(r.Limit, r.Refresh)
	if err != nil {
		return nil, err
	}

	issues := s.recordSet() // the history covers every record
	opts := correlation.DefaultRelatedWorkOptions()
	opts.DependencyGraph = dependencyGraph(issues)
	if r.Limit > 0 {
		opts.MaxResults = r.Limit
	}

	related := result.report.FindRelatedWork(r.ID, opts)
	if related == nil {
		return nil, fmt.Errorf("no history for %q", r.ID)
	}
	return json.Marshal(related)
}

// impactNetwork returns the bead network built from shared commits, shared
// files and declared dependencies.
func (s *Session) impactNetwork(req []byte) ([]byte, error) {
	r, err := decodeHistoryRequest(req)
	if err != nil {
		return nil, err
	}
	result, err := s.correlationHistory(r.Limit, r.Refresh)
	if err != nil {
		return nil, err
	}

	issues := s.recordSet() // the history covers every record
	network := correlation.NewNetworkBuilderWithIssues(result.report, issues).Build()

	depth := r.Depth
	if depth <= 0 {
		depth = 1
	}
	return json.Marshal(network.ToResult(r.ID, depth))
}

// fileBeads answers "which beads touched this file".
func (s *Session) fileBeads(req []byte) ([]byte, error) {
	r, err := decodeHistoryRequest(req)
	if err != nil {
		return nil, err
	}
	if r.Path == "" {
		return nil, fmt.Errorf("file_beads requires a \"path\"")
	}
	result, err := s.correlationHistory(r.Limit, r.Refresh)
	if err != nil {
		return nil, err
	}

	lookup := correlation.NewFileLookup(result.report)
	// A path containing a glob metacharacter is a pattern; anything else is
	// an exact path. Guessing wrong either way returns nothing at all.
	if strings.ContainsAny(r.Path, "*?[") {
		return json.Marshal(lookup.LookupByFileGlob(r.Path))
	}
	return json.Marshal(lookup.LookupByFile(r.Path))
}

// fileHotspots ranks files by how many beads have touched them.
func (s *Session) fileHotspots(req []byte) ([]byte, error) {
	r, err := decodeHistoryRequest(req)
	if err != nil {
		return nil, err
	}
	result, err := s.correlationHistory(r.Limit, r.Refresh)
	if err != nil {
		return nil, err
	}

	limit := r.Limit
	if limit <= 0 {
		limit = 25
	}
	lookup := correlation.NewFileLookup(result.report)
	hotspots := lookup.GetHotspots(limit)
	if hotspots == nil {
		hotspots = []correlation.FileHotspot{}
	}
	return json.Marshal(map[string]any{
		"hotspots": hotspots,
		"stats":    lookup.GetStats(),
	})
}

// fileRelations reports which files change alongside a given file.
func (s *Session) fileRelations(req []byte) ([]byte, error) {
	r, err := decodeHistoryRequest(req)
	if err != nil {
		return nil, err
	}
	if r.Path == "" {
		return nil, fmt.Errorf("file_relations requires a \"path\"")
	}
	result, err := s.correlationHistory(r.Limit, r.Refresh)
	if err != nil {
		return nil, err
	}

	threshold := r.Threshold
	if threshold <= 0 {
		threshold = 0.3
	}
	limit := r.Limit
	if limit <= 0 {
		limit = 20
	}
	lookup := correlation.NewFileLookup(result.report)
	return json.Marshal(lookup.GetRelatedFiles(r.Path, threshold, limit))
}

// orphans reports commits no bead accounts for.
//
// bv's own OrphanDetector re-queries git regardless of the report handed to
// it, so it cannot run under the sandbox. This walks the same report and the
// commit list beside it, and scores each unattributed commit with the same
// four signals bv weighs: timing, files, message and author.
func (s *Session) orphans(req []byte) ([]byte, error) {
	r, err := decodeHistoryRequest(req)
	if err != nil {
		return nil, err
	}
	result, err := s.correlationHistory(r.Limit, r.Refresh)
	if err != nil {
		return nil, err
	}
	issues := s.recordSet() // the history covers every record
	return json.Marshal(detectOrphans(result, issues, r.Limit))
}

// commitPatch renders one commit's diff, optionally narrowed to one file.
func (s *Session) commitPatch(req []byte) ([]byte, error) {
	var r struct {
		SHA  string `json:"sha"`
		Path string `json:"path"`
	}
	if len(req) == 0 {
		return nil, fmt.Errorf("commit_patch requires a \"sha\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	if r.SHA == "" {
		return nil, fmt.Errorf("commit_patch requires a non-empty \"sha\"")
	}

	s.mu.RLock()
	source, issues := s.source, s.records
	s.mu.RUnlock()

	extractor, err := openObjectStore(source, issues)
	if err != nil {
		return nil, err
	}
	text, err := extractor.patch(context.Background(), r.SHA, r.Path)
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{
		"sha":   r.SHA,
		"path":  r.Path,
		"patch": text,
		"bytes": len(text),
	})
}

// titlesByID maps bead ids to titles.
func titlesByID(issues []model.Issue) map[string]string {
	out := make(map[string]string, len(issues))
	for _, issue := range issues {
		out[issue.ID] = issue.Title
	}
	return out
}

// dependencyGraph maps each bead to the beads it depends on.
func dependencyGraph(issues []model.Issue) map[string][]string {
	out := make(map[string][]string, len(issues))
	for _, issue := range issues {
		var deps []string
		for _, dep := range issue.Dependencies {
			if dep == nil {
				continue
			}
			deps = append(deps, dep.DependsOnID)
		}
		if len(deps) > 0 {
			out[issue.ID] = deps
		}
	}
	return out
}

// detectOrphans scores commits that no bead accounts for.
func detectOrphans(
	result *historyResult, issues []model.Issue, limit int,
) correlation.OrphanReport {
	report := result.report
	byID := make(map[string]model.Issue, len(issues))
	for _, issue := range issues {
		byID[issue.ID] = issue
	}

	// Files each bead has touched, for the file-overlap signal.
	beadFiles := map[string]map[string]struct{}{}
	beadAuthors := map[string]string{}
	for id, history := range report.Histories {
		files := map[string]struct{}{}
		for _, commit := range history.Commits {
			for _, file := range commit.Files {
				files[file.Path] = struct{}{}
			}
		}
		beadFiles[id] = files
		beadAuthors[id] = history.LastAuthor
	}

	candidates := []correlation.OrphanCandidate{}
	correlated := 0

	for _, rec := range result.commits {
		if len(report.CommitIndex[rec.sha]) > 0 {
			correlated++
			continue
		}
		// A commit that changed no code is bookkeeping, not lost work.
		if len(rec.codeFiles) == 0 {
			continue
		}

		candidate := scoreOrphan(rec, report, byID, beadFiles, beadAuthors)
		candidates = append(candidates, candidate)
	}

	// Most suspicious first — the point of the list is what to look at.
	sort.SliceStable(candidates, func(a, b int) bool {
		return candidates[a].SuspicionScore > candidates[b].SuspicionScore
	})
	if limit > 0 && len(candidates) > limit {
		candidates = candidates[:limit]
	}

	total := len(result.commits)
	ratio := 0.0
	suspicionSum := 0
	for _, c := range candidates {
		suspicionSum += c.SuspicionScore
	}
	avg := 0.0
	if len(candidates) > 0 {
		avg = float64(suspicionSum) / float64(len(candidates))
	}
	if total > 0 {
		ratio = float64(len(candidates)) / float64(total)
	}

	byBead := map[string][]string{}
	for _, candidate := range candidates {
		for _, probable := range candidate.ProbableBeads {
			byBead[probable.BeadID] = append(byBead[probable.BeadID], candidate.SHA)
		}
	}

	return correlation.OrphanReport{
		GeneratedAt: robotNow(),
		GitRange:    report.GitRange,
		DataHash:    report.DataHash,
		Stats: correlation.OrphanReportStats{
			TotalCommits:    total,
			CorrelatedCount: correlated,
			OrphanCount:     len(candidates),
			CandidateCount:  len(candidates),
			OrphanRatio:     ratio,
			AvgSuspicion:    avg,
		},
		Candidates: candidates,
		ByBead:     byBead,
	}
}

// Signal weights. They sum to 100 so a candidate hitting everything scores
// 100, and each one's contribution is legible in the UI beside the total.
const (
	weightOrphanFiles   = 40
	weightOrphanTiming  = 25
	weightOrphanMessage = 20
	weightOrphanAuthor  = 15
)

// scoreOrphan rates one unattributed commit and names the beads it most
// plausibly belongs to.
func scoreOrphan(
	rec commitRecord,
	report *correlation.HistoryReport,
	byID map[string]model.Issue,
	beadFiles map[string]map[string]struct{},
	beadAuthors map[string]string,
) correlation.OrphanCandidate {
	paths := make([]string, 0, len(rec.codeFiles))
	commitFiles := map[string]struct{}{}
	for _, file := range rec.codeFiles {
		paths = append(paths, file.Path)
		commitFiles[file.Path] = struct{}{}
	}

	type scored struct {
		id      string
		score   int
		reasons []string
	}
	var ranked []scored
	signals := map[correlation.OrphanSignal]correlation.OrphanSignalHit{}

	for id, history := range report.Histories {
		score := 0
		var reasons []string

		overlap := 0
		for path := range beadFiles[id] {
			if _, hit := commitFiles[path]; hit {
				overlap++
			}
		}
		if overlap > 0 {
			score += weightOrphanFiles
			reasons = append(reasons, fmt.Sprintf("%d file(s) also touched by this bead", overlap))
			signals[correlation.SignalOrphanFiles] = correlation.OrphanSignalHit{
				Signal:  correlation.SignalOrphanFiles,
				Details: fmt.Sprintf("%d shared file(s)", overlap),
				Weight:  weightOrphanFiles,
			}
		}

		if withinActiveWindow(rec.when, history) {
			score += weightOrphanTiming
			reasons = append(reasons, "committed while the bead was in progress")
			signals[correlation.SignalOrphanTiming] = correlation.OrphanSignalHit{
				Signal:  correlation.SignalOrphanTiming,
				Details: "inside the bead's active window",
				Weight:  weightOrphanTiming,
			}
		}

		if issue, ok := byID[id]; ok && titleEchoesMessage(issue.Title, rec.message) {
			score += weightOrphanMessage
			reasons = append(reasons, "message echoes the bead's title")
			signals[correlation.SignalOrphanMessage] = correlation.OrphanSignalHit{
				Signal:  correlation.SignalOrphanMessage,
				Details: "shared wording with the bead title",
				Weight:  weightOrphanMessage,
			}
		}

		if author := beadAuthors[id]; author != "" && author == rec.author {
			score += weightOrphanAuthor
			reasons = append(reasons, "same author as the bead's last activity")
			signals[correlation.SignalOrphanAuthor] = correlation.OrphanSignalHit{
				Signal:  correlation.SignalOrphanAuthor,
				Details: rec.author,
				Weight:  weightOrphanAuthor,
			}
		}

		if score > 0 {
			ranked = append(ranked, scored{id: id, score: score, reasons: reasons})
		}
	}

	sort.SliceStable(ranked, func(a, b int) bool {
		if ranked[a].score != ranked[b].score {
			return ranked[a].score > ranked[b].score
		}
		return ranked[a].id < ranked[b].id
	})
	if len(ranked) > 5 {
		ranked = ranked[:5]
	}

	probable := make([]correlation.ProbableBead, 0, len(ranked))
	for _, entry := range ranked {
		issue := byID[entry.id]
		probable = append(probable, correlation.ProbableBead{
			BeadID:     entry.id,
			BeadTitle:  issue.Title,
			BeadStatus: string(issue.Status),
			Confidence: entry.score,
			Reasons:    entry.reasons,
		})
	}

	// The commit's own suspicion is its best candidate's score: a commit with
	// one strong explanation is more worth reviewing than one with several
	// weak ones.
	suspicion := 0
	if len(probable) > 0 {
		suspicion = probable[0].Confidence
	}

	hits := make([]correlation.OrphanSignalHit, 0, len(signals))
	for _, hit := range signals {
		hits = append(hits, hit)
	}
	sort.SliceStable(hits, func(a, b int) bool { return hits[a].Weight > hits[b].Weight })

	return correlation.OrphanCandidate{
		SHA:            rec.sha,
		ShortSHA:       rec.shortSHA,
		Message:        rec.message,
		Author:         rec.author,
		AuthorEmail:    rec.email,
		Timestamp:      rec.when,
		Files:          paths,
		SuspicionScore: suspicion,
		ProbableBeads:  probable,
		Signals:        hits,
	}
}

// withinActiveWindow reports whether a commit landed while the bead was open.
func withinActiveWindow(when time.Time, history correlation.BeadHistory) bool {
	start := history.Milestones.Claimed
	if start == nil {
		start = history.Milestones.Created
	}
	if start == nil {
		return false
	}
	if when.Before(start.Timestamp) {
		return false
	}
	if closed := history.Milestones.Closed; closed != nil {
		return !when.After(closed.Timestamp)
	}
	// Still open, so anything after it started is inside the window.
	return true
}

// titleEchoesMessage reports whether a commit message shares distinctive
// wording with a bead title.
//
// Short and common words are skipped: matching on "the" would make every
// commit look related to every bead.
func titleEchoesMessage(title, message string) bool {
	lowerMessage := strings.ToLower(message)
	hits := 0
	for _, word := range strings.Fields(strings.ToLower(title)) {
		word = strings.Trim(word, ".,:;()[]\"'`")
		if len(word) < 5 || commonWords[word] {
			continue
		}
		if strings.Contains(lowerMessage, word) {
			hits++
		}
	}
	return hits >= 2
}

var commonWords = map[string]bool{
	"about": true, "after": true, "again": true, "there": true, "their": true,
	"these": true, "those": true, "which": true, "while": true, "would": true,
	"should": true, "could": true, "where": true, "other": true, "using": true,
	"through": true, "between": true, "rather": true, "instead": true,
}
