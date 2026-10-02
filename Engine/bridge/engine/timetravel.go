package engine

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
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

// extractor opens the object store for the current source.
func (s *Session) extractor() (*objectStoreExtractor, error) {
	s.mu.RLock()
	source, issues := s.source, s.records
	s.mu.RUnlock()
	if source == "" {
		return nil, fmt.Errorf("session has no source")
	}
	return openObjectStore(source, issues)
}

// revisions lists the points the time-travel scrubber can jump to.
func (s *Session) revisions(req []byte) ([]byte, error) {
	r, err := s.decodeRevision(req)
	if err != nil {
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
	// their beads (vbx-d1c).
	s.mu.RLock()
	isWorkspace := s.kind == "workspace"
	s.mu.RUnlock()
	if isWorkspace && isHeadRevision(r.Revision) {
		return s.workspaceHeadSnapshot(r)
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

// diffSince compares the current bead set against an earlier revision.
func (s *Session) diffSince(req []byte) ([]byte, error) {
	r, err := s.decodeRevision(req)
	if err != nil {
		return nil, err
	}
	if r.Revision == "" {
		return nil, fmt.Errorf("diff requires a \"revision\"")
	}

	extractor, err := s.extractor()
	if err != nil {
		return nil, err
	}
	hash, err := extractor.resolve(r.Revision)
	if err != nil {
		return nil, err
	}
	historical, when, err := extractor.issuesAt(hash)
	if err != nil {
		return nil, err
	}

	// Every record, tombstones included, because the historical side is read
	// the same way: comparing it with the analysis set would report every
	// tombstone as removed.
	current := s.recordSet()
	from := analysis.NewSnapshotAt(historical, when, hash.String())
	to := analysis.NewSnapshot(current)
	diff := analysis.CompareSnapshots(from, to)

	return json.Marshal(map[string]any{
		"requested_revision": r.Revision,
		"resolved_revision":  hash.String(),
		"short_revision":     shortHash(hash.String()),
		"from_data_hash":     analysis.ComputeDataHash(historical),
		"to_data_hash":       analysis.ComputeDataHash(current),
		"diff":               diff,
		"badges":             diffBadges(diff),
	})
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
