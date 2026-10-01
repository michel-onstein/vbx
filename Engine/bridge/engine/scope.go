package engine

import (
	"encoding/json"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// bv 0.25.2's --label is a global scope, not a per-command filter. Its
// scopeLoadedIssues (cmd/bv/main.go) runs once, before any robot handler:
// the loaded issues are swapped for the label subgraph's AllIssues — the
// labelled beads plus their direct dependency neighbours — and the labelled
// CoreIssues become the candidates, the beads a command may recommend. Every
// handler then analyses that set afresh through RobotContext.Analyzer, while
// the envelope keeps the unscoped data hash and hashes the candidates into
// scope_hash. An unknown label is an empty selection that still carries its
// envelope.
//
// vbx ports that one step here, and every label-aware method reads its issues,
// analyzer and provenance scope from it, so no command carries its own copy of
// the rule. bv exports no function doing the selection, which is why it is
// ported rather than called.

// robotView is the issue set a robot method answers over.
type robotView struct {
	// issues is the analysis set: the session's visible beads, or the label
	// subgraph.
	issues []model.Issue
	// analyzer and stats are the session's own when unscoped, and built
	// afresh over issues when scoped; scoped stats have finished Phase 2.
	analyzer *analysis.Analyzer
	stats    *analysis.GraphStats
	// candidates are the beads a command may recommend. Nil means all of
	// issues; an empty map — an unknown label — means none.
	candidates map[string]bool
	// dataHash is the unscoped data hash in both cases, as bv's envelope
	// carries it.
	dataHash string
	// scope is the provenance scope behind scope_hash and the envelope's
	// `scope`.
	scope provenanceScope
}

// scoped reports whether a label narrowed the view.
func (v robotView) scoped() bool { return v.scope.label != "" }

// view returns the session's analysis set under label, or the whole set when
// label is empty.
func (s *Session) view(label string) robotView {
	issues, analyzer, stats := s.snapshot()
	v := robotView{issues: issues, analyzer: analyzer, stats: stats}
	if analyzer != nil {
		v.dataHash = analyzer.DataHash()
	}
	if label == "" {
		return v
	}

	subgraph := analysis.ComputeLabelSubgraph(issues, label)
	scoped := make([]model.Issue, 0, len(subgraph.AllIssues))
	for _, id := range subgraph.AllIssues {
		if issue, ok := subgraph.IssueMap[id]; ok {
			scoped = append(scoped, issue)
		}
	}
	candidates := make(map[string]bool, len(subgraph.CoreIssues))
	for _, id := range subgraph.CoreIssues {
		candidates[id] = true
	}

	// The scoped analyzer is this call's alone; the methods that read its
	// clock pin it through pinClock exactly as they pin the session's.
	an, st := s.analyse(scoped, s.readinessIndex(), candidates)
	st.WaitForPhase2()

	v.issues, v.analyzer, v.stats, v.candidates = scoped, an, st, candidates
	v.scope = provenanceScope{
		label:      label,
		candidates: append([]string{}, subgraph.CoreIssues...),
	}
	return v
}

// seedHash is the data hash a triage may seed its analyzer with: only the
// unscoped one describes the issues it analyses, so a scoped view seeds
// nothing — bv's DataHashMatchesIssues.
func (v robotView) seedHash() string {
	if v.scoped() {
		return ""
	}
	return v.dataHash
}

// labelRequest decodes the `label` every label-aware method accepts. A
// request that is absent or carries no label is the unscoped view.
func labelRequest(req []byte) (string, error) {
	var r struct {
		Label string `json:"label"`
	}
	if len(req) == 0 {
		return "", nil
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return "", err
	}
	return r.Label, nil
}
