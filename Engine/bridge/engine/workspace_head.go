package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// The committed bead set of a multi-repository workspace (vbx-d1c).
//
// A workspace session's source is `.bv/workspace.yaml`, so the ordinary
// `snapshot_at` opens the object store of whichever repository holds that
// file and looks there for a beads file at the path of the yaml. A member is
// normally its own repository, with its own HEAD, so its beads were compared
// against the wrong repository — or against nothing — and the app's
// uncommitted marks were wrong for every member.
//
// So `HEAD` is resolved per member: each member's own object store, at its
// own HEAD, reading the beads file its records were actually loaded from, and
// namespaced exactly as the loader namespaced them. The union is the
// workspace's committed set. A member whose history cannot be read — no
// repository, no commits — is reported by its record ids as unknown rather
// than left out, because left out its beads would all read as added: absent
// is not zero (ADR-015).

// memberHead is how one member's HEAD resolved.
type memberHead struct {
	Name             string `json:"name"`
	Prefix           string `json:"prefix"`
	ResolvedRevision string `json:"resolved_revision,omitempty"`
	Error            string `json:"error,omitempty"`
}

// isHeadRevision reports whether a request names HEAD — the one revision that
// means something in every member at once. A SHA belongs to one repository.
func isHeadRevision(revision string) bool {
	r := strings.TrimSpace(revision)
	return r == "" || r == "HEAD"
}

// workspaceHeadSnapshot is `snapshot_at` for HEAD in a workspace session.
func (s *Session) workspaceHeadSnapshot(r revisionRequest) ([]byte, error) {
	s.mu.RLock()
	loads, records := s.repoLoads, s.records
	s.mu.RUnlock()

	known := map[string]bool{}
	for _, load := range loads {
		if load.Prefix != "" {
			known[load.Prefix] = true
		}
	}

	committed := []model.Issue{}
	unknownIDs := []string{}
	heads := []memberHead{}
	hashes := map[string]bool{}
	var newest time.Time
	readable := 0

	for _, load := range loads {
		if load.disabled || load.Error != "" || load.sourcePath == "" {
			// A member that did not load has no records on screen, so there is
			// nothing of it to mark either way.
			continue
		}
		head := memberHead{Name: load.Name, Prefix: load.Prefix}
		issues, hash, when, err := memberIssuesAtHead(load, known)
		if err != nil {
			head.Error = err.Error()
			unknownIDs = append(unknownIDs, memberRecordIDs(records, load.Prefix)...)
		} else {
			head.ResolvedRevision = hash
			hashes[hash] = true
			committed = append(committed, issues...)
			readable++
			if when.After(newest) {
				newest = when
			}
		}
		heads = append(heads, head)
	}

	if readable == 0 {
		return nil, fmt.Errorf("no member of the workspace has a commit to compare against")
	}
	sort.Strings(unknownIDs)

	// One resolved commit only when every member is the same commit — the
	// members of a monorepo. Otherwise there is no single answer, and the
	// per-member list says what each one was.
	resolved := ""
	if len(hashes) == 1 {
		for hash := range hashes {
			resolved = hash
		}
	}

	return json.Marshal(map[string]any{
		"requested_revision": r.Revision,
		"resolved_revision":  resolved,
		"short_revision":     shortHash(resolved),
		"timestamp":          newest,
		"issue_count":        len(committed),
		"data_hash":          analysis.ComputeDataHash(committed),
		"issues":             committed,
		"repos":              heads,
		"unknown_ids":        unknownIDs,
	})
}

// memberIssuesAtHead reads one member's beads as of its own HEAD, namespaced.
//
// The namespacing is the loader's, so a committed record and its working copy
// carry the same id and the same `source_repo`; tombstones are dropped for
// the same reason the loader drops them from the working set.
func memberIssuesAtHead(load repoLoad, known map[string]bool) ([]model.Issue, string, time.Time, error) {
	extractor, err := openObjectStore(load.sourcePath, nil)
	if err != nil {
		return nil, "", time.Time{}, err
	}
	hash, err := extractor.resolve("HEAD")
	if err != nil {
		return nil, "", time.Time{}, err
	}
	issues, when, err := extractor.issuesAt(hash)
	if err != nil {
		return nil, "", time.Time{}, err
	}

	localIDs := make(map[string]bool, len(issues))
	for _, issue := range issues {
		localIDs[issue.ID] = true
	}
	visible := make([]model.Issue, 0, len(issues))
	for _, issue := range issues {
		if !issue.Status.IsTombstone() {
			visible = append(visible, issue)
		}
	}
	return namespaceIssues(visible, load.Prefix, localIDs, known), hash.String(), when, nil
}

// memberRecordIDs lists the loaded records that came from the member with
// this prefix, by the `source_repo` the loader stamped on each.
func memberRecordIDs(records []model.Issue, prefix string) []string {
	key := sourceRepoKeyFromPrefix(prefix)
	ids := []string{}
	for _, issue := range records {
		if issue.SourceRepo == key {
			ids = append(ids, issue.ID)
		}
	}
	return ids
}

// gitWatchPathsLocked lists the git directories of a workspace's members, for
// the app's repository watch. Callers hold s.mu.
//
// The app watches the git directory of the repository the workspace root is
// in; a commit in a member moves a different HEAD, and without these its
// marks would never clear. Empty for a single repository, whose git directory
// the app already finds itself.
func (s *Session) gitWatchPathsLocked() []string {
	dirs := []string{}
	if s.kind != "workspace" {
		return dirs
	}
	seen := map[string]bool{}
	for _, load := range s.repoLoads {
		if load.disabled || load.sourcePath == "" {
			continue
		}
		dir := gitDirOf(filepath.Dir(load.sourcePath))
		if dir == "" || seen[dir] {
			continue
		}
		seen[dir] = true
		dirs = append(dirs, dir)
	}
	return dirs
}

// gitDirOf finds the git directory of the repository containing dir, or ""
// when it is in none.
//
// `.git` is a directory in an ordinary clone and a file holding a `gitdir:`
// pointer in a linked worktree or a submodule, where the pointed-at directory
// is the one whose HEAD and index move on a commit. The same walk the app's
// `gitHeadPath` makes, so the two agree on what "the repository" is.
func gitDirOf(dir string) string {
	dir = filepath.Clean(dir)
	for {
		dot := filepath.Join(dir, ".git")
		if info, err := os.Stat(dot); err == nil {
			if info.IsDir() {
				return dot
			}
			return gitDirFromFile(dot)
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// gitDirFromFile follows a `.git` file's `gitdir:` line. Anything else is a
// file this does not understand, and guessing would watch a path that is not
// there.
func gitDirFromFile(dot string) string {
	contents, err := os.ReadFile(dot)
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(contents), "\n")
	if !strings.HasPrefix(line, "gitdir:") {
		return ""
	}
	target := strings.TrimSpace(strings.TrimPrefix(line, "gitdir:"))
	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(dot), target)
	}
	if info, err := os.Stat(target); err != nil || !info.IsDir() {
		return ""
	}
	return filepath.Clean(target)
}
