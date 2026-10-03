package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// Time travel: the bead set as of an arbitrary revision, and what changed
// since.
//
// bv reaches history through `loader.GitLoader`, which shells out to `git`
// exactly as `pkg/correlation` does, so the same constraint applies and the
// same answer: read the object store. The comparison itself is bv's —
// `analysis.NewSnapshotAt` and `analysis.CompareSnapshots` are pure.

type revisionRequest struct {
	// Revision is any expression git would accept: a SHA, `HEAD~3`, a branch
	// or a tag. Empty means HEAD.
	Revision string `json:"revision"`
	Limit    int    `json:"limit"`
	// The scope is bv's --label and --recipe (scope.go), which only the diff
	// reads: bv compares the historical beads with its scoped current ones.
	scopeRequest
}

func (s *Session) decodeRevision(req []byte) (revisionRequest, error) {
	var r revisionRequest
	if len(req) == 0 {
		return r, nil
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return r, err
	}
	return r, nil
}

// errWorkspaceTimeTravel is why a multi-repository workspace offers no time
// travel (ADR-028, vbx-bcq).
//
// The session's source is the workspace yaml, so the one object store
// `extractor` can open is the repository holding that file — not a member's.
// Its revisions are commits that changed the yaml, and a diff against one
// reads the yaml as the bead set: every bead "new". A member is normally a
// repository of its own, so a revision names a commit in at most one of them,
// and there is no single "the workspace at HEAD~3" to show. bv has none
// either: its --as-of ignores --workspace, and its --diff-since reads the
// working directory's repository whatever --workspace says.
//
// HEAD alone has a workspace meaning — each member at its own HEAD — and
// `snapshot_at` answers it per member (workspace_head.go, vbx-d1c).
var errWorkspaceTimeTravel = errors.New(
	"time travel is not available in a multi-repository workspace: " +
		"each member is its own repository, so a revision names a commit in at most one of them")

// refuseWorkspaceTimeTravel is errWorkspaceTimeTravel for a workspace
// session, and nil for any other.
func (s *Session) refuseWorkspaceTimeTravel() error {
	s.mu.RLock()
	isWorkspace := s.kind == "workspace"
	s.mu.RUnlock()
	if isWorkspace {
		return errWorkspaceTimeTravel
	}
	return nil
}

// extractor opens the object store for the current source.
func (s *Session) extractor() (*objectStoreExtractor, error) {
	s.mu.RLock()
	source := s.source
	s.mu.RUnlock()
	if source == "" {
		return nil, fmt.Errorf("session has no source")
	}
	return openObjectStore(source)
}

// revisions lists the points the time-travel scrubber can jump to.
func (s *Session) revisions(req []byte) ([]byte, error) {
	r, err := s.decodeRevision(req)
	if err != nil {
		return nil, err
	}
	if err := s.refuseWorkspaceTimeTravel(); err != nil {
		return nil, err
	}
	extractor, err := s.extractor()
	if err != nil {
		return nil, err
	}
	list, err := extractor.revisions(context.Background(), r.Limit)
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{"revisions": list, "count": len(list)})
}

// snapshotAt returns the bead set as of a revision.
//
// The response echoes the *resolved* commit, never the user's expression:
// `HEAD~3` means something different tomorrow, and a UI that displayed the raw
// input would keep claiming to show a snapshot it is no longer showing.
func (s *Session) snapshotAt(req []byte) ([]byte, error) {
	r, err := s.decodeRevision(req)
	if err != nil {
		return nil, err
	}
	// A workspace's members are separate repositories with a HEAD each; the
	// session's source is the workspace yaml, whose repository holds none of
	// their beads (vbx-d1c). HEAD means each member's own; any other revision
	// means nothing across them (vbx-bcq).
	if err := s.refuseWorkspaceTimeTravel(); err != nil {
		if isHeadRevision(r.Revision) {
			return s.workspaceHeadSnapshot(r)
		}
		return nil, err
	}
	extractor, err := s.extractor()
	if err != nil {
		return nil, err
	}

	hash, err := extractor.resolve(r.Revision)
	if err != nil {
		return nil, err
	}
	issues, when, err := extractor.issuesAt(hash)
	if err != nil {
		return nil, err
	}

	return json.Marshal(map[string]any{
		"requested_revision": r.Revision,
		"resolved_revision":  hash.String(),
		"short_revision":     shortHash(hash.String()),
		"timestamp":          when,
		"issue_count":        len(issues),
		"data_hash":          analysis.ComputeDataHash(issues),
		"issues":             issues,
	})
}

// diffSince compares the current bead set against an earlier revision, as
// bv 0.25.2's --diff-since --robot-diff does (cmd/bv/main.go and the
// robot-diff handler in robot_registry.go):
//
//   - Both sides are the visible beads. bv's history loader drops tombstones
//     from a historical read exactly as its live load does, so a bead deleted
//     since the revision is removed rather than modified, and one deleted
//     before it is on neither side.
//   - The historical side is the whole revision; the current side is the
//     scope's issues — under --label the label's subgraph, under --recipe its
//     selection. A bead outside the scope therefore reads as removed.
//   - The from-snapshot carries no timestamp (bv passes the zero time) and
//     the to-snapshot is stamped with the pinned clock.
//   - to_data_hash and the envelope's data_hash are the unscoped hash, and
//     the envelope names the scope and hashes it.
//
// requested_revision, short_revision and badges are vbx's own additions for
// the time-travel view; bv has no counterpart.
func (s *Session) diffSince(req []byte) ([]byte, error) {
	r, err := s.decodeRevision(req)
	if err != nil {
		return nil, err
	}
	if r.Revision == "" {
		return nil, fmt.Errorf("diff requires a \"revision\"")
	}
	if err := s.refuseWorkspaceTimeTravel(); err != nil {
		return nil, err
	}
	v, err := s.view(r.scopeRequest)
	if err != nil {
		return nil, err
	}

	extractor, err := s.extractor()
	if err != nil {
		return nil, err
	}
	hash, err := extractor.resolve(r.Revision)
	if err != nil {
		return nil, err
	}
	records, _, err := extractor.issuesAt(hash)
	if err != nil {
		return nil, err
	}
	historical := withoutTombstones(records)

	from := analysis.NewSnapshotAt(historical, time.Time{}, hash.String())
	to := analysis.NewSnapshot(v.issues)
	diff := analysis.CompareSnapshots(from, to)
	diff.ToTimestamp = robotNow()

	return s.withEnvelope(map[string]any{
		"requested_revision": r.Revision,
		"resolved_revision":  hash.String(),
		"short_revision":     shortHash(hash.String()),
		"from_data_hash":     analysis.ComputeDataHash(historical),
		"to_data_hash":       v.dataHash,
		"diff":               diff,
		"badges":             diffBadges(diff),
	}, v.dataHash, v.scope)
}

// withoutTombstones is the visible part of a record set, as bv's loaders
// return it.
func withoutTombstones(records []model.Issue) []model.Issue {
	visible := make([]model.Issue, 0, len(records))
	for _, issue := range records {
		if !issue.Status.IsTombstone() {
			visible = append(visible, issue)
		}
	}
	return visible
}

// diffBadges reduces a snapshot diff to one label per changed bead.
//
// The view needs "what happened to this bead" keyed by id; the diff carries
// parallel lists instead. Reopened is applied last on purpose: a bead can
// appear in both the reopened and the modified list, and "reopened" is the
// more informative of the two.
func diffBadges(diff *analysis.SnapshotDiff) map[string]string {
	badges := map[string]string{}
	if diff == nil {
		return badges
	}
	for _, issue := range diff.NewIssues {
		badges[issue.ID] = "new"
	}
	for _, issue := range diff.RemovedIssues {
		badges[issue.ID] = "removed"
	}
	for _, modified := range diff.ModifiedIssues {
		badges[modified.IssueID] = "modified"
	}
	for _, issue := range diff.ClosedIssues {
		badges[issue.ID] = "closed"
	}
	for _, issue := range diff.ReopenedIssues {
		badges[issue.ID] = "reopened"
	}
	return badges
}
