package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/search"
)

// Search.
//
// bv has exactly two modes, and the naming is worth stating plainly because it
// is easy to get wrong: there is no separate "fuzzy" and "semantic" mode. The
// vector index is *always* used to find candidates; the mode selects what
// re-ranks them. `text` takes the index's own similarity; `hybrid` re-scores
// with graph metrics — centrality, actionability, impact, priority, recency —
// through bv's own scorer.
//
// The default embedder is `hash`, which is deterministic and needs no model.
// That is what keeps vbx's default ranking identical to the CLI's: a better
// embedder would give better results and *different* ones, so choosing it is
// the caller's decision, never a default.

// A query that is a bead id is guaranteed that bead, first, even when its text
// similarity would not have put it among the fetched candidates. That rule is
// bv's, applied by bv's own VectorIndex.SearchTopKWithOptions: an exact-case
// match wins, and a case-folded one counts only when it is unambiguous. Ids are
// opaque, so the query is not required to look like one.

type searchRequest struct {
	Query string `json:"query"`
	Limit int    `json:"limit"`
	// Mode is "text" or "hybrid". Empty means text.
	Mode string `json:"mode"`
	// Preset names a weight set: default, bug-hunting, sprint-planning,
	// impact-first, text-only.
	Preset string `json:"preset"`
	// Weights overrides the preset entirely. All six keys are required.
	Weights *search.Weights `json:"weights"`
	// Embedder selects the vector provider. Empty means the environment's,
	// which defaults to the deterministic hash embedder.
	Embedder string `json:"embedder"`
	// MinScore is bv's --search-min-score: an inclusive threshold on the raw
	// text similarity, applied before the lexical boost and hybrid ranking.
	// An exact-id hit obeys it too. Absent means no threshold.
	MinScore *float64 `json:"min_score"`
}

// searchIssues runs one query.
func (s *Session) searchIssues(req []byte) ([]byte, error) {
	var r searchRequest
	if len(req) == 0 {
		return nil, fmt.Errorf("search requires a \"query\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	if strings.TrimSpace(r.Query) == "" {
		return nil, fmt.Errorf("search requires a non-empty \"query\"")
	}

	limit := r.Limit
	if limit <= 0 {
		limit = 10
	}
	mode := strings.ToLower(strings.TrimSpace(r.Mode))
	if mode == "" {
		mode = "text"
	}
	if mode != "text" && mode != "hybrid" {
		return nil, fmt.Errorf("invalid search mode %q (expected text or hybrid)", mode)
	}
	if err := validateMinScore(r.MinScore); err != nil {
		return nil, err
	}

	issues, _, _ := s.snapshot()
	if len(issues) == 0 {
		payload := map[string]any{"query": r.Query, "mode": mode, "results": []any{}}
		if r.MinScore != nil {
			payload["min_score"] = *r.MinScore
		}
		return json.Marshal(payload)
	}

	embedConfig := search.EmbeddingConfigFromEnv()
	if r.Embedder != "" {
		embedConfig.Provider = search.Provider(r.Embedder)
		embedConfig = embedConfig.Normalized()
	}
	embedder, err := search.NewEmbedderFromConfig(embedConfig)
	if err != nil {
		return nil, fmt.Errorf("creating embedder: %w", err)
	}

	docs := search.DocumentsFromIssues(issues)
	index, err := s.vectorIndex(embedder, docs, embedConfig)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	vectors, err := embedder.Embed(ctx, []string{r.Query})
	if err != nil || len(vectors) == 0 {
		return nil, fmt.Errorf("embedding the query: %w", err)
	}

	// Hybrid re-ranks, so it needs more candidates than it will return —
	// otherwise re-scoring can only reorder what text similarity already
	// chose, and a bead the metrics would have promoted is never seen.
	fetch := limit
	if mode == "hybrid" {
		fetch = search.HybridCandidateLimit(limit, len(issues), r.Query)
	}

	// bv's search, through bv's options: the short-query lexical boost is
	// added before top-K, so a literal match cannot be cut before it is
	// boosted; the threshold applies to the raw similarity, before the boost;
	// and an exact id is guaranteed a place, first.
	var boosts map[string]float64
	if search.IsShortQuery(r.Query) {
		boosts = make(map[string]float64)
		for id, doc := range docs {
			if boost := search.ShortQueryLexicalBoost(r.Query, doc); boost > 0 {
				boosts[id] = boost
			}
		}
	}
	results, err := index.SearchTopKWithOptions(vectors[0], fetch, search.VectorSearchOptions{
		ExactID: r.Query, MinScore: r.MinScore, ScoreBoosts: boosts,
	})
	if err != nil {
		return nil, fmt.Errorf("searching: %w", err)
	}
	exactID := ""
	for _, result := range results {
		if result.ExactIDMatch {
			exactID = result.IssueID
			break
		}
	}
	titles := make(map[string]string, len(issues))
	for _, issue := range issues {
		titles[issue.ID] = issue.Title
	}

	payload := map[string]any{
		"query":       r.Query,
		"mode":        mode,
		"provider":    string(embedder.Provider()),
		"dim":         embedder.Dim(),
		"index_size":  index.Size(),
		"limit":       limit,
		"total_beads": len(issues),
	}
	if r.MinScore != nil {
		// bv echoes the threshold only when one was given.
		payload["min_score"] = *r.MinScore
	}

	if mode == "text" {
		payload["results"] = textResults(results, limit, titles)
		return json.Marshal(payload)
	}

	weights, preset, err := resolveWeights(r)
	if err != nil {
		return nil, err
	}
	scored, err := hybridResults(results, issues, weights, exactID, limit, titles)
	if err != nil {
		return nil, err
	}
	payload["results"] = scored
	payload["preset"] = preset
	payload["weights"] = weights
	return json.Marshal(payload)
}

// vectorIndex loads or builds the workspace's vector index.
func (s *Session) vectorIndex(
	embedder search.Embedder, docs map[string]string, cfg search.EmbeddingConfig,
) (*search.VectorIndex, error) {
	dir := s.projectDir()
	if dir == "" {
		return nil, fmt.Errorf("session has no source")
	}
	path := search.DefaultIndexPath(dir, cfg)

	index, loaded, err := search.LoadOrNewVectorIndex(path, embedder.Dim())
	if err != nil {
		return nil, fmt.Errorf("opening the search index: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	stats, err := search.SyncVectorIndex(ctx, index, embedder, docs, 64)
	if err != nil {
		return nil, fmt.Errorf("indexing: %w", err)
	}
	if !loaded || stats.Changed() {
		// A save failure costs the next query its warm start, not this
		// query's answer, so it is not fatal.
		_ = index.Save(path)
	}
	return index, nil
}

// resolveWeights turns a preset name or an explicit set into weights.
func resolveWeights(r searchRequest) (search.Weights, string, error) {
	if r.Weights != nil {
		weights := r.Weights.Normalize()
		if err := weights.Validate(); err != nil {
			return search.Weights{}, "", fmt.Errorf("invalid weights: %w", err)
		}
		// bv labels an explicit set "custom" rather than naming a preset it
		// no longer matches.
		return search.AdjustWeightsForQuery(weights, r.Query), "custom", nil
	}

	name := r.Preset
	if name == "" {
		name = "default"
	}
	weights, err := search.GetPreset(search.PresetName(strings.ToLower(name)))
	if err != nil {
		return search.Weights{}, "", fmt.Errorf("unknown search preset %q", name)
	}
	return search.AdjustWeightsForQuery(weights.Normalize(), r.Query), name, nil
}

// textResults trims to the limit and shapes the payload, carrying each bead's
// title as bv's does.
func textResults(results []search.SearchResult, limit int, titles map[string]string) []map[string]any {
	if len(results) > limit {
		results = results[:limit]
	}
	out := make([]map[string]any, 0, len(results))
	for _, result := range results {
		entry := map[string]any{"issue_id": result.IssueID, "score": result.Score}
		if title := titles[result.IssueID]; title != "" {
			entry["title"] = title
		}
		out = append(out, entry)
	}
	return out
}

// hybridResults re-scores candidates with graph metrics. exactID is the bead
// the index marked as the query's exact-id match, or empty.
func hybridResults(
	candidates []search.SearchResult, issues []model.Issue,
	weights search.Weights, exactID string, limit int, titles map[string]string,
) ([]map[string]any, error) {
	cache := search.NewMetricsCache(search.NewAnalyzerMetricsLoader(issues))
	if err := cache.Refresh(); err != nil {
		return nil, fmt.Errorf("loading metrics for hybrid ranking: %w", err)
	}
	scorer := search.NewHybridScorer(weights, cache)

	scored := make([]search.HybridScore, 0, len(candidates))
	for _, candidate := range candidates {
		score, err := scorer.Score(candidate.IssueID, candidate.Score)
		if err != nil {
			continue
		}
		scored = append(scored, score)
	}

	sort.SliceStable(scored, func(i, j int) bool {
		if scored[i].FinalScore != scored[j].FinalScore {
			return scored[i].FinalScore > scored[j].FinalScore
		}
		// Ties break on id, so the same query twice gives the same order.
		return scored[i].IssueID < scored[j].IssueID
	})

	for i := range scored {
		if exactID == "" || scored[i].IssueID != exactID {
			continue
		}
		// Re-ranking can bury the bead whose id was literally typed. Rotating
		// it back to the front preserves the relative order of the rest, as
		// bv's promoteExactHybridResult does.
		match := scored[i]
		copy(scored[1:i+1], scored[:i])
		scored[0] = match
		break
	}

	if len(scored) > limit {
		scored = scored[:limit]
	}

	out := make([]map[string]any, 0, len(scored))
	for _, score := range scored {
		entry := map[string]any{"issue_id": score.IssueID, "score": score.FinalScore}
		// bv's field is omitempty, so a zero text score is absent there too.
		if score.TextScore != 0 {
			entry["text_score"] = score.TextScore
		}
		if title := titles[score.IssueID]; title != "" {
			entry["title"] = title
		}
		if len(score.ComponentScores) > 0 {
			// The breakdown is what makes a hybrid ranking auditable rather
			// than a number to take on trust.
			entry["component_scores"] = score.ComponentScores
		}
		out = append(out, entry)
	}
	return out, nil
}

// validateMinScore applies bv's range: a finite number from -1 to 1, the
// span of a cosine similarity. bv checks the flag's text in the CLI
// (parseSearchMinScore); a request arrives already parsed, so the same bounds
// are applied to the number.
func validateMinScore(score *float64) error {
	if score == nil {
		return nil
	}
	if math.IsNaN(*score) || math.IsInf(*score, 0) || *score < -1 || *score > 1 {
		return fmt.Errorf("invalid min_score %v (expected a finite number from -1 to 1)", *score)
	}
	return nil
}

// searchPresets lists the weight sets available, with their values.
func (s *Session) searchPresets() ([]byte, error) {
	names := []string{"default", "bug-hunting", "sprint-planning", "impact-first", "text-only"}
	entries := make([]map[string]any, 0, len(names))
	for _, name := range names {
		weights, err := search.GetPreset(search.PresetName(name))
		if err != nil {
			continue
		}
		entries = append(entries, map[string]any{"name": name, "weights": weights})
	}
	return json.Marshal(map[string]any{
		"presets": entries,
		"modes":   []string{"text", "hybrid"},
	})
}
