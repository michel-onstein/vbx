package engine

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// bv 0.25's robot envelope carries provenance built in `cmd/bv`, which vbx
// cannot import. ADR-023 decides it key by key:
//
//   - output_format, source_path, source_kind and scope_hash are ported here.
//     Each is computable from what the session already holds and means what
//     it means in bv.
//   - load_stats is too (vbx-dv5): bv derives it from the source authority,
//     but only from each source's parse accounting, which vbx's loads keep.
//     Present only when a record was dropped. See loadstats.go.
//   - source_authority and authority_hash are not. They report bv's
//     multi-source selection — candidates ranked by freshness, a stale
//     fallback, per-source authority warnings — and vbx resolves one source
//     without ranking any (ADR-024). A ported value would assert checks vbx
//     never ran, so the parity harness declares them envelope-only instead.
//
// The values are vbx's own, never bv's: in a br 0.7 workspace bv reads
// beads.db where vbx reads issues.jsonl, and the two then disagree on
// source_path and source_kind. ADR-024 keeps vbx's choice; see it for why.

// provenanceScope is the scoping a payload was computed under, for its
// scope_hash. The zero value is the whole project.
type provenanceScope struct {
	label string
	// recipe is the --recipe argument as given — a name or a path — which is
	// what bv reports and hashes.
	recipe string
	// candidates are the beads the payload selects from, when that is not
	// every visible bead — a label scope's core beads, narrowed to what a
	// recipe selected. Nil means all.
	candidates []string
}

// sourceKindForEnvelope names the loaded source in bv's vocabulary. vbx's
// own kind is "jsonl" for the workspace's local JSONL, which bv calls
// jsonl_local; vbx has no counterpart of bv's jsonl_worktree.
func sourceKindForEnvelope(kind string) string {
	if kind == "jsonl" {
		return "jsonl_local"
	}
	return kind
}

// scopeHash is bv's robotScopeHash: the scope's flags, the unscoped data hash
// and the sorted candidate ids, marshalled in that struct shape and hashed.
// The field names and order are part of the hash, so the struct is bv's
// verbatim. vbx has no repo scope on a robot payload, so that is always
// empty.
func scopeHash(label, recipeArg, dataHash string, ids []string) string {
	raw, err := json.Marshal(struct {
		Label, Recipe, Repo, DataHash string
		IDs                           []string
	}{label, recipeArg, "", dataHash, ids})
	if err != nil {
		return ""
	}
	return fmt.Sprintf("%x", sha256.Sum256(raw))
}

// scopeIDs returns the sorted ids a scope selects from issues — every visible
// bead, or only the candidates when the scope names some.
func scopeIDs(issues []model.Issue, scope provenanceScope) []string {
	var keep map[string]bool
	if scope.candidates != nil {
		keep = make(map[string]bool, len(scope.candidates))
		for _, id := range scope.candidates {
			keep[id] = true
		}
	}
	ids := make([]string, 0, len(issues))
	for _, issue := range issues {
		if keep == nil || keep[issue.ID] {
			ids = append(ids, issue.ID)
		}
	}
	sort.Strings(ids)
	return ids
}

// provenance returns the envelope keys vbx ports, for a payload computed over
// the session's visible beads with the given data hash.
//
// output_format is "json" because the engine returns JSON; vbx-cli rewrites it
// when it re-encodes the payload as TOON.
func (s *Session) provenance(dataHash string, scope provenanceScope) map[string]any {
	s.mu.RLock()
	source, kind, issues, sources := s.source, s.kind, s.issues, s.sourceLoads
	s.mu.RUnlock()

	envelope := map[string]any{
		"output_format": "json",
		"scope_hash":    scopeHash(scope.label, scope.recipe, dataHash, scopeIDs(issues, scope)),
	}
	if source != "" {
		envelope["source_path"] = source
	}
	if kind != "" {
		envelope["source_kind"] = sourceKindForEnvelope(kind)
	}
	if stats := robotLoadStats(sources); stats != nil {
		envelope["load_stats"] = stats
	}
	// bv's RobotScope: each flag only when it was given.
	if scope.label != "" || scope.recipe != "" {
		named := map[string]any{}
		if scope.label != "" {
			named["label"] = scope.label
		}
		if scope.recipe != "" {
			named["recipe"] = scope.recipe
		}
		envelope["scope"] = named
	}
	return envelope
}

// withProvenance marshals payload and adds the provenance keys at its top
// level. A key the payload already has is left alone: the payload's own
// field is data, and the envelope must never overwrite it.
func (s *Session) withProvenance(payload any, dataHash string, scope provenanceScope) ([]byte, error) {
	return mergeTopLevel(payload, s.provenance(dataHash, scope))
}

// withEnvelope is withProvenance for a payload that has no envelope of its
// own: bv's generated_at and data_hash join the provenance keys. Each is
// added only where the payload has no field of that name, so label health
// keeps its own generated_at.
func (s *Session) withEnvelope(payload any, dataHash string, scope provenanceScope) ([]byte, error) {
	keys := s.provenance(dataHash, scope)
	keys["generated_at"] = robotNow().UTC().Format(time.RFC3339)
	keys["data_hash"] = dataHash
	return mergeTopLevel(payload, keys)
}

// mergeTopLevel marshals payload, which must encode as a JSON object, and
// adds keys at its top level, leaving every key the payload already has.
func mergeTopLevel(payload any, keys map[string]any) ([]byte, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil {
		return nil, fmt.Errorf("provenance needs a JSON object: %w", err)
	}
	if object == nil {
		return nil, fmt.Errorf("provenance needs a JSON object, not null")
	}
	for key, value := range keys {
		if _, taken := object[key]; taken {
			continue
		}
		encoded, err := json.Marshal(value)
		if err != nil {
			return nil, err
		}
		object[key] = encoded
	}
	return json.Marshal(object)
}
