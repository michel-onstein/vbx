package engine

// The nine history commands — history, causality, related, impact network,
// orphans, file beads, file hotspots, file relations and file impact — are
// bv 0.25.2's own handlers, ported from cmd/bv/robot_registry.go, over bv's
// own correlator. The correlator is vbx's copy of bv's pkg/correlation
// (Engine/bridge/correlation, ADR-027), identical but for how it reaches git:
// every git command line it runs is answered in-process from the object store
// (package objgit), because the App Sandbox cannot spawn git (ADR-006).
//
// Each report is built from the request's scope, as bv builds it from its
// scoped ctx.Issues: the histories are those of the scope's beads, the data
// hash is theirs, and the envelope names the scope (ADR-023). Only the git
// extraction — the expensive part, and independent of the bead set — is
// cached, per session, keyed by HEAD and the walk's options; the cheap
// assembly runs per request, so feedback and scope changes apply at once.

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	bvcorrelation "github.com/Dicklesworthstone/beads_viewer/pkg/correlation"
	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/recipe"
	"github.com/qjam/vbx/engine/correlation"
	"github.com/qjam/vbx/engine/objgit"
)

// defaultHistoryLimit is bv's --history-limit default: the commits walked.
const defaultHistoryLimit = 500

// historyRequest is the shared request of the history methods. Each key is
// named after the bv flag it carries.
type historyRequest struct {
	scopeRequest
	// ID names a bead: --bead-history, --robot-causality, --robot-related,
	// and --robot-impact-network's bead ("all" or empty for the whole
	// network).
	ID string `json:"id"`
	// Path names a file: --robot-file-beads, --robot-file-relations.
	Path string `json:"path"`
	// Files are --robot-impact's paths.
	Files []string `json:"files"`
	// HistoryLimit is --history-limit: commits walked, 0 for all. Absent
	// means bv's default of 500.
	HistoryLimit *int `json:"history_limit"`
	// HistorySince is --history-since, which history and causality honour.
	HistorySince string `json:"history_since"`
	// MinConfidence is --min-confidence, which history honours.
	MinConfidence float64 `json:"min_confidence"`
	// HotspotsLimit is --hotspots-limit (default 10).
	HotspotsLimit *int `json:"hotspots_limit"`
	// RelationsThreshold and RelationsLimit are --relations-threshold
	// (default 0.5) and --relations-limit (default 10).
	RelationsThreshold *float64 `json:"relations_threshold"`
	RelationsLimit     *int     `json:"relations_limit"`
	// FileBeadsLimit is --file-beads-limit: closed beads listed (default 20).
	FileBeadsLimit *int `json:"file_beads_limit"`
	// NetworkDepth is --network-depth (default 2, clamped to 1..3).
	NetworkDepth *int `json:"network_depth"`
	// RelatedMinRelevance is --related-min-relevance as a percent (default
	// 20), RelatedMaxResults --related-max-results (default 10) and
	// RelatedIncludeClosed --related-include-closed.
	RelatedMinRelevance  *int `json:"related_min_relevance"`
	RelatedMaxResults    *int `json:"related_max_results"`
	RelatedIncludeClosed bool `json:"related_include_closed"`
	// OrphansMinScore is --orphans-min-score (default 30).
	OrphansMinScore *int `json:"orphans_min_score"`
	// Refresh discards the session's cached extraction and walks again.
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

func intOr(v *int, fallback int) int {
	if v == nil {
		return fallback
	}
	return *v
}

func floatOr(v *float64, fallback float64) float64 {
	if v == nil {
		return fallback
	}
	return *v
}

// historyLimit is the walk's commit limit.
func (r historyRequest) historyLimit() int { return intOr(r.HistoryLimit, defaultHistoryLimit) }

// since parses --history-since against vbx's clock, as bv parses it against
// robotNow: a relative phrase ("30 days ago") or a date.
func (r historyRequest) since() (*time.Time, error) {
	if strings.TrimSpace(r.HistorySince) == "" {
		return nil, nil
	}
	since, err := recipe.ParseRelativeTime(r.HistorySince, robotNow())
	if err != nil {
		return nil, fmt.Errorf("parsing --history-since: %w", err)
	}
	if since.IsZero() {
		return nil, nil
	}
	return &since, nil
}

// historyPlace is where a session's history lives: the directory bv runs
// git in, and the beads JSONL it follows.
type historyPlace struct {
	workDir   string
	beadsDir  string
	beadsPath string
}

// historyPlace resolves the workspace's directory and beads JSONL as bv's
// handlers do: the directory holding `.beads`, and loader.FindJSONLPath in
// the beads directory — the JSONL even where the session loaded a beads.db.
//
// Unlike bv, the directory need not hold `.git` itself: objgit finds the
// repository that contains it, so a workspace nested in a repository has a
// history in vbx where bv reports "not a git repository".
func (s *Session) historyPlace() (historyPlace, error) {
	s.mu.RLock()
	source := s.source
	s.mu.RUnlock()
	if source == "" {
		return historyPlace{}, fmt.Errorf("session has no source")
	}
	beadsDir := filepath.Dir(source)
	beadsPath, err := loader.FindJSONLPath(beadsDir)
	if err != nil {
		return historyPlace{}, fmt.Errorf("finding beads file: %w", err)
	}
	return historyPlace{workDir: filepath.Dir(beadsDir), beadsDir: beadsDir, beadsPath: beadsPath}, nil
}

// historyArtifact returns the extraction for the options, from the
// session's cache when HEAD has not moved since it was taken. The lock is
// held through an extraction, so two requests arriving together walk once.
func (s *Session) historyArtifact(place historyPlace, opts correlation.CorrelatorOptions, refresh bool) (*correlation.HistoryArtifact, error) {
	head := "unborn"
	// The explicit-id strategy runs during extraction, so the id patterns
	// are part of what an extraction depends on.
	patterns, _ := s.historyIDPatterns()
	var out strings.Builder
	if err := objgit.Run(context.Background(), place.workDir, []string{"rev-parse", "HEAD"}, nil, &out); err == nil {
		head = strings.TrimSpace(out.String())
	}
	key := func(o correlation.CorrelatorOptions) string {
		since := ""
		if o.Since != nil {
			since = o.Since.UTC().Format(time.RFC3339)
		}
		return fmt.Sprintf("%s|%s|%s|%d|%s|%s|%s|%q", place.workDir, place.beadsPath, head, o.Limit,
			since, o.BeadID, o.CausalityBeadID, patterns)
	}

	s.historyMu.Lock()
	defer s.historyMu.Unlock()
	if refresh || s.historyArtifacts == nil {
		s.historyArtifacts = map[string]*correlation.HistoryArtifact{}
	}
	c := s.newCorrelator(place)

	// The walk is shared by every report over the same options; causality
	// adds its target's full record to it rather than walking again.
	plain := opts
	plain.CausalityBeadID = ""
	base, ok := s.historyArtifacts[key(plain)]
	if !ok {
		var err error
		if base, err = c.ExtractArtifact(plain); err != nil {
			return nil, fmt.Errorf("generating history report: %w", err)
		}
		s.historyArtifacts[key(plain)] = base
	}
	if opts.CausalityBeadID == "" {
		return base, nil
	}
	if art, ok := s.historyArtifacts[key(opts)]; ok {
		return art, nil
	}
	causal, err := c.ExtractCausalHistory(opts.CausalityBeadID, opts)
	if err != nil {
		return nil, fmt.Errorf("generating history report: extracting causal history: %w", err)
	}
	art := base.WithCausalHistory(causal)
	s.historyArtifacts[key(opts)] = art
	return art, nil
}

// invalidateHistory drops the cached extractions. Called whenever the
// workspace reloads; HEAD moving is caught by the cache key as well.
func (s *Session) invalidateHistory() {
	s.historyMu.Lock()
	s.historyArtifacts = nil
	s.historyMu.Unlock()
}

// beadInfos is bv's buildCorrelationBeadInfos.
func beadInfos(issues []model.Issue) []correlation.BeadInfo {
	out := make([]correlation.BeadInfo, len(issues))
	for i, issue := range issues {
		out[i] = correlation.BeadInfo{ID: issue.ID, Title: issue.Title, Status: string(issue.Status)}
	}
	return out
}

// historyReport is bv's generateCorrelationReport over the scope's issues:
// the report for those beads, with stored confirm/reject feedback applied
// unless raw is set (bv's generateRawCorrelationReport, for the verdicts
// themselves).
func (s *Session) historyReport(issues []model.Issue, opts correlation.CorrelatorOptions, refresh, raw bool) (*correlation.HistoryReport, historyPlace, error) {
	place, err := s.historyPlace()
	if err != nil {
		return nil, place, err
	}
	art, err := s.historyArtifact(place, opts, refresh)
	if err != nil {
		return nil, place, err
	}
	c := s.newCorrelator(place)
	if !raw {
		store := correlation.NewFeedbackStore(place.beadsDir)
		if err := store.Load(); err != nil {
			return nil, place, fmt.Errorf("loading feedback: %w", err)
		}
		c = c.WithFeedbackStore(store)
	}
	report := c.AssembleReport(beadInfos(issues), opts, art)
	report.GeneratedAt = robotNow()
	return report, place, nil
}

// historyView decodes a history request and resolves its scope.
func (s *Session) historyView(req []byte) (historyRequest, robotView, error) {
	r, err := decodeHistoryRequest(req)
	if err != nil {
		return r, robotView{}, err
	}
	v, err := s.view(r.scopeRequest)
	if err != nil {
		return r, robotView{}, err
	}
	return r, v, nil
}

// overlayEnvelope is bv's withEnvelope: the payload with the robot envelope
// laid over its top level. Where the two share a key — a correlation
// result's own generated_at and data_hash — the envelope's value wins.
func (s *Session) overlayEnvelope(payload any, dataHash string, scope provenanceScope) ([]byte, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil {
		return nil, fmt.Errorf("payload is not a JSON object: %w", err)
	}
	delete(object, "generated_at")
	delete(object, "data_hash")
	return s.withEnvelope(object, dataHash, scope)
}

// historyPayload is --robot-history (and --bead-history, with an id).
func (s *Session) historyPayload(req []byte) ([]byte, error) {
	r, v, err := s.historyView(req)
	if err != nil {
		return nil, err
	}
	since, err := r.since()
	if err != nil {
		return nil, err
	}
	opts := correlation.CorrelatorOptions{BeadID: r.ID, Limit: r.historyLimit(), Since: since}
	report, _, err := s.historyReport(v.issues, opts, r.Refresh, false)
	if err != nil {
		return nil, err
	}
	if r.MinConfidence > 0 {
		scorer := correlation.NewScorer()
		report.Histories = scorer.FilterHistoriesByConfidence(report.Histories, r.MinConfidence)
		report.CommitIndex = correlation.BuildCommitIndex(report.Histories)
		report.Stats.BeadsWithCommits = 0
		for _, history := range report.Histories {
			if len(history.Commits) > 0 {
				report.Stats.BeadsWithCommits++
			}
		}
	}
	return s.withEnvelope(struct {
		GitRange        string                             `json:"git_range"`
		LatestCommitSHA string                             `json:"latest_commit_sha,omitempty"`
		Window          *correlation.HistoryWindow         `json:"window,omitempty"`
		Stats           correlation.HistoryStats           `json:"stats"`
		Histories       map[string]correlation.BeadHistory `json:"histories"`
		CommitIndex     correlation.CommitIndex            `json:"commit_index"`
	}{report.GitRange, report.LatestCommitSHA, report.Window, report.Stats, report.Histories,
		report.CommitIndex}, report.DataHash, v.scope)
}

// causality is --robot-causality: one bead's causal chain, over its full
// committed record.
func (s *Session) causality(req []byte) ([]byte, error) {
	r, v, err := s.historyView(req)
	if err != nil {
		return nil, err
	}
	if r.ID == "" {
		return nil, fmt.Errorf("causality requires an \"id\"")
	}
	since, err := r.since()
	if err != nil {
		return nil, err
	}
	opts := correlation.CorrelatorOptions{Limit: r.historyLimit(), CausalityBeadID: r.ID, Since: since}
	report, _, err := s.historyReport(v.issues, opts, r.Refresh, false)
	if err != nil {
		return nil, err
	}
	result := report.BuildCausalityChainAt(r.ID, correlation.CausalityOptions{
		IncludeCommits: true,
		BlockerTitles:  titlesByID(v.issues),
	}, robotNow())
	if result == nil {
		return nil, fmt.Errorf("Bead not found: %s", r.ID)
	}
	return s.overlayEnvelope(result, report.DataHash, v.scope)
}

// relatedWork is --robot-related: beads sharing files, commits, dependencies
// or a working window with one bead.
func (s *Session) relatedWork(req []byte) ([]byte, error) {
	r, v, err := s.historyView(req)
	if err != nil {
		return nil, err
	}
	if r.ID == "" {
		return nil, fmt.Errorf("related requires an \"id\"")
	}
	report, _, err := s.historyReport(v.issues, correlation.CorrelatorOptions{Limit: r.historyLimit()}, r.Refresh, false)
	if err != nil {
		return nil, err
	}
	options := correlation.RelatedWorkOptions{
		ConcurrencyWindow: 7 * 24 * time.Hour,
		DependencyGraph:   dependencyGraph(v.issues),
		MinRelevance:      intOr(r.RelatedMinRelevance, 20),
		MaxResults:        intOr(r.RelatedMaxResults, 10),
		IncludeClosed:     r.RelatedIncludeClosed,
	}
	result := report.FindRelatedWorkAt(r.ID, options, robotNow())
	if result == nil {
		return nil, fmt.Errorf("Bead not found in history: %s", r.ID)
	}
	return s.overlayEnvelope(result, report.DataHash, v.scope)
}

// impactNetwork is --robot-impact-network: the bead network built from shared
// commits, shared files and dependencies, whole ("all" or no id) or around one
// bead.
func (s *Session) impactNetwork(req []byte) ([]byte, error) {
	r, v, err := s.historyView(req)
	if err != nil {
		return nil, err
	}
	report, _, err := s.historyReport(v.issues, correlation.CorrelatorOptions{Limit: r.historyLimit()}, r.Refresh, false)
	if err != nil {
		return nil, err
	}
	network := correlation.NewNetworkBuilderWithIssues(report, v.issues).BuildAt(robotNow())
	beadID := r.ID
	if beadID == "all" {
		beadID = ""
	}
	if beadID != "" {
		if _, ok := network.Nodes[beadID]; !ok {
			return nil, fmt.Errorf("Bead not found in network: %s", beadID)
		}
	}
	depth := intOr(r.NetworkDepth, 2)
	if depth < 1 {
		depth = 1
	}
	if depth > 3 {
		depth = 3
	}
	return s.overlayEnvelope(network.ToResult(beadID, depth), report.DataHash, v.scope)
}

// orphans is --robot-orphans: commits in the walked window no bead accounts
// for, scored by bv's detector, which reads the window through objgit.
func (s *Session) orphans(req []byte) ([]byte, error) {
	r, v, err := s.historyView(req)
	if err != nil {
		return nil, err
	}
	limit := r.historyLimit()
	report, place, err := s.historyReport(v.issues, correlation.CorrelatorOptions{Limit: limit}, r.Refresh, false)
	if err != nil {
		return nil, err
	}
	// The detector reads the custom id patterns while it scores, so it runs
	// with the session's registered.
	_, patterns := s.historyIDPatterns()
	var orphanReport *correlation.OrphanReport
	withIDPatterns(patterns, func() {
		orphanReport, err = correlation.NewOrphanDetectorAt(report, place.workDir, robotNow()).
			DetectOrphans(correlation.ExtractOptions{Limit: limit})
	})
	if err != nil {
		return nil, fmt.Errorf("detecting orphans: %w", err)
	}
	filterOrphanReportByMinScore(orphanReport, intOr(r.OrphansMinScore, 30))
	return s.withEnvelope(struct {
		GitRange   string                        `json:"git_range"`
		Window     correlation.OrphanWindow      `json:"window"`
		Stats      correlation.OrphanReportStats `json:"stats"`
		Candidates []correlation.OrphanCandidate `json:"candidates"`
		ByBead     map[string][]string           `json:"by_bead,omitempty"`
		UsageHints []string                      `json:"usage_hints"`
	}{orphanReport.GitRange, orphanReport.Window, orphanReport.Stats, orphanReport.Candidates,
		orphanReport.ByBead, orphanReport.UsageHints}, orphanReport.DataHash, v.scope)
}

// filterOrphanReportByMinScore is bv's: candidates under the score are
// dropped, and the per-bead index and the averages follow.
func filterOrphanReportByMinScore(orphanReport *correlation.OrphanReport, minScore int) {
	filtered := make([]correlation.OrphanCandidate, 0, len(orphanReport.Candidates))
	byBead := make(map[string][]string)
	totalSuspicion := 0
	for _, candidate := range orphanReport.Candidates {
		if candidate.SuspicionScore < minScore {
			continue
		}
		filtered = append(filtered, candidate)
		totalSuspicion += candidate.SuspicionScore
		for _, bead := range candidate.ProbableBeads {
			byBead[bead.BeadID] = append(byBead[bead.BeadID], candidate.ShortSHA)
		}
	}
	orphanReport.Candidates = filtered
	orphanReport.ByBead = byBead
	orphanReport.Stats.CandidateCount = len(filtered)
	orphanReport.Stats.AvgSuspicion = 0
	if len(filtered) > 0 {
		orphanReport.Stats.AvgSuspicion = float64(totalSuspicion) / float64(len(filtered))
	}
}

// fileBeads is --robot-file-beads: the beads that touched a file. A path
// holding a glob character (`*`, `?`, `[`) is matched as a glob — vbx's
// extension, which the History view's file search uses; bv looks such a path
// up literally, so its answer for one is empty.
func (s *Session) fileBeads(req []byte) ([]byte, error) {
	r, v, err := s.historyView(req)
	if err != nil {
		return nil, err
	}
	if r.Path == "" {
		return nil, fmt.Errorf("file_beads requires a \"path\"")
	}
	report, _, err := s.historyReport(v.issues, correlation.CorrelatorOptions{Limit: r.historyLimit()}, r.Refresh, false)
	if err != nil {
		return nil, err
	}
	lookup := correlation.NewFileLookup(report)
	var result *correlation.FileBeadLookupResult
	if strings.ContainsAny(r.Path, "*?[") {
		result = lookup.LookupByFileGlob(r.Path)
	} else {
		result = lookup.LookupByFile(r.Path)
	}
	closedLimit := intOr(r.FileBeadsLimit, 20)
	if closedLimit < 0 {
		closedLimit = 0
	}
	if len(result.ClosedBeads) > closedLimit {
		result.ClosedBeads = result.ClosedBeads[:closedLimit]
	}
	return s.withEnvelope(struct {
		FilePath    string                      `json:"file_path"`
		TotalBeads  int                         `json:"total_beads"`
		OpenBeads   []correlation.BeadReference `json:"open_beads"`
		ClosedBeads []correlation.BeadReference `json:"closed_beads"`
	}{r.Path, result.TotalBeads, result.OpenBeads, result.ClosedBeads}, report.DataHash, v.scope)
}

// fileHotspots is --robot-file-hotspots: files ranked by the beads that
// touched them.
func (s *Session) fileHotspots(req []byte) ([]byte, error) {
	r, v, err := s.historyView(req)
	if err != nil {
		return nil, err
	}
	report, _, err := s.historyReport(v.issues, correlation.CorrelatorOptions{Limit: r.historyLimit()}, r.Refresh, false)
	if err != nil {
		return nil, err
	}
	lookup := correlation.NewFileLookup(report)
	return s.withEnvelope(struct {
		Hotspots []correlation.FileHotspot  `json:"hotspots"`
		Stats    correlation.FileIndexStats `json:"stats"`
	}{lookup.GetHotspots(intOr(r.HotspotsLimit, 10)), lookup.GetStats()}, report.DataHash, v.scope)
}

// fileRelations is --robot-file-relations: files that change alongside one.
func (s *Session) fileRelations(req []byte) ([]byte, error) {
	r, v, err := s.historyView(req)
	if err != nil {
		return nil, err
	}
	if r.Path == "" {
		return nil, fmt.Errorf("file_relations requires a \"path\"")
	}
	report, _, err := s.historyReport(v.issues, correlation.CorrelatorOptions{Limit: r.historyLimit()}, r.Refresh, false)
	if err != nil {
		return nil, err
	}
	result := correlation.NewFileLookup(report).GetRelatedFiles(
		r.Path, floatOr(r.RelationsThreshold, 0.5), intOr(r.RelationsLimit, 10))
	return s.withEnvelope(struct {
		FilePath     string                      `json:"file_path"`
		TotalCommits int                         `json:"total_commits"`
		Threshold    float64                     `json:"threshold"`
		RelatedFiles []correlation.CoChangeEntry `json:"related_files"`
	}{result.FilePath, result.TotalCommits, result.Threshold, result.RelatedFiles}, report.DataHash, v.scope)
}

// fileImpact is --robot-impact: the risk of changing a set of files, from the
// beads that touched them.
func (s *Session) fileImpact(req []byte) ([]byte, error) {
	r, v, err := s.historyView(req)
	if err != nil {
		return nil, err
	}
	var files []string
	for _, f := range r.Files {
		files = append(files, strings.TrimSpace(f))
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("file_impact requires a non-empty \"files\"")
	}
	report, _, err := s.historyReport(v.issues, correlation.CorrelatorOptions{Limit: r.historyLimit()}, r.Refresh, false)
	if err != nil {
		return nil, err
	}
	impact := correlation.NewFileLookup(report).ImpactAnalysisAt(files, robotNow())
	return s.withEnvelope(struct {
		Files         []string                   `json:"files"`
		RiskLevel     string                     `json:"risk_level"`
		RiskScore     float64                    `json:"risk_score"`
		Summary       string                     `json:"summary"`
		Warnings      []string                   `json:"warnings"`
		AffectedBeads []correlation.AffectedBead `json:"affected_beads"`
	}{impact.Files, impact.RiskLevel, impact.RiskScore, impact.Summary, impact.Warnings,
		impact.AffectedBeads}, report.DataHash, v.scope)
}

// triageReport is the history triage scores staleness with: bv's bounded
// report over the triage's issues, in bv's own type, which is what its
// scorer takes. The copy and the original share every JSON field name, so a
// round trip through JSON converts one to the other.
func (s *Session) triageReport(issues []model.Issue) (*bvcorrelation.HistoryReport, error) {
	report, _, err := s.historyReport(issues, correlation.CorrelatorOptions{Limit: triageHistoryLimit}, false, false)
	if err != nil {
		return nil, err
	}
	raw, err := json.Marshal(report)
	if err != nil {
		return nil, err
	}
	var converted bvcorrelation.HistoryReport
	if err := json.Unmarshal(raw, &converted); err != nil {
		return nil, err
	}
	return &converted, nil
}

// feedbackStore opens the workspace's correlation feedback sidecar.
func (s *Session) feedbackStore() (*correlation.FeedbackStore, error) {
	place, err := s.historyPlace()
	if err != nil {
		s.mu.RLock()
		source := s.source
		s.mu.RUnlock()
		if source == "" {
			return nil, err
		}
		place.beadsDir = filepath.Dir(source)
	}
	store := correlation.NewFeedbackStore(place.beadsDir)
	if err := store.Load(); err != nil {
		return nil, err
	}
	return store, nil
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

// recordFeedback confirms or rejects one link. The confidence recorded
// beside the verdict is the strategy's own, read from the report without
// feedback applied — bv's generateRawCorrelationReport — so a second verdict
// on the same link does not record the first one's pinned 1.0.
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
	original := 0.0
	if report, _, err := s.historyReport(s.wholeView().issues,
		correlation.CorrelatorOptions{Limit: defaultHistoryLimit}, false, true); err == nil {
		for _, commit := range report.Histories[r.BeadID].Commits {
			if commit.SHA == r.SHA {
				original = commit.Confidence
			}
		}
	}

	switch verdict {
	case correlation.FeedbackReject:
		err = store.Reject(r.SHA, r.BeadID, r.By, original, r.Reason)
	default:
		err = store.Confirm(r.SHA, r.BeadID, r.By, original, r.Reason)
	}
	if err != nil {
		return nil, err
	}
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
	source := s.source
	s.mu.RUnlock()

	extractor, err := openObjectStore(source)
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

// dependencyGraph maps each bead to the beads it depends on, every type
// included, as bv's --robot-related builds it.
func dependencyGraph(issues []model.Issue) map[string][]string {
	out := make(map[string][]string, len(issues))
	for _, issue := range issues {
		for _, dep := range issue.Dependencies {
			if dep == nil {
				continue
			}
			out[issue.ID] = append(out[issue.ID], dep.DependsOnID)
		}
	}
	return out
}
