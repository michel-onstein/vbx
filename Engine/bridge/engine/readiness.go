package engine

import (
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// Tombstones and readiness authority, the way bv 0.25 splits them.
//
// bv keeps two scopes apart. The *visible* set — every record except
// tombstones — is what the graph, triage, label health, suggestions and the
// data hash are computed over. The *readiness authority* is the full source,
// tombstones included, because a deleted bead is a resolved blocker: drop it
// and its dependents wait on a blocker that no longer exists, which bv's
// ReadinessIndex reads as "unknown" and withholds for ever.
//
// vbx keeps a third thing bv does not: the tombstone's whole record. Decoding
// never drops a record, so the `issues` payload still carries it and the app
// decides what to show; only the analysis input leaves it out. See ADR-021.

// visibleIssues returns the records bv analyses: everything but tombstones.
//
// The result shares no backing array with records, so binding origins or
// sorting one never reorders the other.
func visibleIssues(records []model.Issue) []model.Issue {
	visible := make([]model.Issue, 0, len(records))
	for _, issue := range records {
		if !issue.Status.IsTombstone() {
			visible = append(visible, issue)
		}
	}
	return visible
}

// readinessAuthority builds bv's ReadinessIndex over readinessInput.
func readinessAuthority(records []model.Issue, tombstoneIDs []string) *model.ReadinessIndex {
	return model.NewReadinessIndex(readinessInput(records, tombstoneIDs))
}

// readinessInput is every record plus a tombstone stub for each id a loader
// reported deleted without keeping its record (bv's workspace loader does
// that) — bv's issuesWithTombstones. An id already present as a record is not
// stubbed over.
func readinessInput(records []model.Issue, tombstoneIDs []string) []model.Issue {
	if len(tombstoneIDs) == 0 {
		return records
	}
	all := make([]model.Issue, 0, len(records)+len(tombstoneIDs))
	all = append(all, records...)
	seen := make(map[string]bool, len(records))
	for _, issue := range records {
		seen[issue.ID] = true
	}
	for _, id := range tombstoneIDs {
		if !seen[id] {
			seen[id] = true
			all = append(all, model.Issue{ID: id, Status: model.StatusTombstone})
		}
	}
	return all
}
