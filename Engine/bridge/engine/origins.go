package engine

import (
	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// Issue origins: which live tracker a bead came from, and so which commands
// can act on it.
//
// bv 0.25 binds every loaded bead to its tracker (`loader.AttachIssueOrigins`)
// and derives each recommendation's `actions` — a `br show` and, for a
// claimable bead, a `br update --claim` — from that binding. Establishing it
// means asking the installed `br` what it supports: `br update --help`, run as
// a subprocess with a two-second timeout. The App Sandbox forbids that, so the
// binding is made only when the session was opened with LiveTrackerActions,
// which only vbx-cli does. See ADR-020.
//
// The app still binds every bead, to an origin that carries the bead's id and
// the reason its actions are unavailable. That keeps the payload's shape the
// same in both — `local_id` is present either way — and makes "no claim
// command" an explained absence rather than an empty field, which is the rule
// for every unavailable value in vbx.

// appActionsUnavailable is the reason the app gives for every bead's actions.
const appActionsUnavailable = "live tracker actions are resolved by vbx-cli, not the app"

// incompleteAuthority is bv's reason for withholding a claim from a partial
// load.
const incompleteAuthority = "source authority is incomplete or stale"

// attachLiveOrigins is bv's binding, a variable only so a test can prove the
// app never reaches it.
var attachLiveOrigins = loader.AttachIssueOrigins

// bindOrigins binds a single source's beads to their tracker.
func (s *Session) bindOrigins(issues []model.Issue, source string, complete bool) {
	if s.config.LiveTrackerActions {
		attachLiveOrigins(issues, source, complete)
		return
	}
	bindAppOrigins(issues)
}

// bindWorkspaceOrigins handles a multi-repository load.
//
// bv's workspace loader binds origins itself, per repository and before it
// namespaces the ids, so the CLI has nothing to add. The app replaces those
// bindings with its own, keeping the local id bv recorded.
func (s *Session) bindWorkspaceOrigins(issues []model.Issue) {
	if !s.config.LiveTrackerActions {
		bindAppOrigins(issues)
	}
}

// bindAppOrigins gives every bead an origin that names it and explains why it
// has no runnable actions.
func bindAppOrigins(issues []model.Issue) {
	for i := range issues {
		local := issues[i].ID
		if issues[i].Origin != nil && issues[i].Origin.LocalID != "" {
			local = issues[i].Origin.LocalID
		}
		issues[i].Origin = &model.IssueOrigin{
			LocalID:        local,
			ReadOnlyReason: appActionsUnavailable,
		}
	}
}

// suppressUnprovenTriageClaims withdraws every claim from a triage computed
// over a partial load — bv's function of the same name, which lives in
// `cmd/bv` and so cannot be imported.
func suppressUnprovenTriageClaims(triage *analysis.TriageResult) {
	triage.Commands.ClaimTop = ""
	triage.QuickRef.TopPicks = []analysis.TopPick{}
	triage.QuickWins = []analysis.QuickWin{}
	suppress := func(recs []analysis.Recommendation) {
		for i := range recs {
			recs[i].Claimable = false
			recs[i].Actions.Claim = nil
			recs[i].Actions.UnavailableReason = incompleteAuthority
			recs[i].Action = "Inspect source diagnostics before claiming work"
		}
	}
	suppress(triage.Recommendations)
	for i := range triage.BlockersToClear {
		triage.BlockersToClear[i].Actionable = false
	}
	for i := range triage.RecommendationsByTrack {
		group := &triage.RecommendationsByTrack[i]
		group.TopPick, group.ClaimCommand = nil, ""
		suppress(group.Recommendations)
	}
	for i := range triage.RecommendationsByLabel {
		group := &triage.RecommendationsByLabel[i]
		group.TopPick, group.ClaimCommand = nil, ""
		suppress(group.Recommendations)
	}
}

// claimsProven reports whether the loaded data may back a claim.
func (s *Session) claimsProven() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.complete
}
