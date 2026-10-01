package engine

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/storer"
)

// Sprint scope changes — which beads joined or left a sprint mid-flight.
//
// Ported from bv v0.25.2's unexported `computeSprintScopeChanges` (cmd/bv
// main.go). bv runs `git log -p -U0` over `.beads/sprints.jsonl` and reads the
// sprint's line either side of each hunk; the App Sandbox forbids that
// subprocess, so this reads the same commits from the object store directly,
// as ADR-006 requires. The answer is the same: for each non-merge commit in
// the sprint's window that changed the file, the sprint's bead set before and
// after, and the difference between them.

const (
	scopeAdded   = "added"
	scopeRemoved = "removed"
)

// scopeChange is one bead joining or leaving a sprint — bv's ScopeChangeEvent.
type scopeChange struct {
	Date       time.Time `json:"date"`
	IssueID    string    `json:"issue_id"`
	IssueTitle string    `json:"issue_title"`
	Action     string    `json:"action"`
}

// scopeCommit is one commit's worth of changes, kept apart until they are
// ordered.
type scopeCommit struct {
	when time.Time
	// order is the commit's position in the newest-first walk. Git dates have
	// one-second granularity, so ties are common and need a stable breaker.
	order  int
	events []scopeChange
}

// sprintScopeChanges walks the sprint file's history within the sprint.
//
// It returns nil, not an error, wherever bv returns nothing: a sprint without
// both dates, and a workspace root that is not itself a repository — bv only
// looks for `.git` beside `.beads`, so a workspace nested inside some larger
// repository has no scope history in either tool.
func sprintScopeChanges(
	root string, sprint *model.Sprint, byID map[string]model.Issue, now time.Time,
) ([]scopeChange, error) {
	if root == "" || sprint == nil || sprint.ID == "" {
		return nil, nil
	}
	if sprint.StartDate.IsZero() || sprint.EndDate.IsZero() {
		return nil, nil
	}
	if _, err := os.Stat(filepath.Join(root, ".git")); err != nil {
		return nil, nil
	}

	// EnableDotGitCommonDir, so a linked worktree resolves HEAD — see
	// openObjectStore.
	repo, err := git.PlainOpenWithOptions(root, &git.PlainOpenOptions{EnableDotGitCommonDir: true})
	if err != nil {
		return nil, fmt.Errorf("opening git repository at %s: %w", root, err)
	}
	head, err := repo.Head()
	if err != nil {
		return nil, fmt.Errorf("resolving HEAD: %w", err)
	}

	// The window is bv's: from the day before the sprint to its end or now,
	// whichever is sooner, both ends inclusive at git's one-second
	// resolution.
	since := sprint.StartDate.AddDate(0, 0, -1).Truncate(time.Second)
	until := sprint.EndDate
	if until.After(now) {
		until = now
	}
	until = until.Truncate(time.Second)

	iter, err := repo.Log(&git.LogOptions{From: head.Hash(), Order: git.LogOrderCommitterTime})
	if err != nil {
		return nil, fmt.Errorf("walking history: %w", err)
	}
	defer iter.Close()

	sprintsPath := path.Join(".beads", loader.SprintsFileName)
	var commits []scopeCommit
	err = iter.ForEach(func(commit *object.Commit) error {
		when := commit.Committer.When
		if when.Before(since) {
			// `git log --since` stops at the first commit older than the
			// cutoff, and the walk is newest-first.
			return storer.ErrStop
		}
		if when.After(until) {
			return nil
		}
		// A merge shows no patch in `git log -p`, and a root commit has
		// nothing on the old side: neither can move a bead between two
		// versions of the sprint.
		if commit.NumParents() != 1 {
			return nil
		}
		parent, err := commit.Parent(0)
		if err != nil {
			return err
		}
		before, haveBefore, err := sprintAt(parent, sprintsPath, sprint.ID)
		if err != nil {
			return err
		}
		after, haveAfter, err := sprintAt(commit, sprintsPath, sprint.ID)
		if err != nil {
			return err
		}
		if !haveBefore || !haveAfter {
			return nil
		}

		added := setDifference(after, before)
		removed := setDifference(before, after)
		if len(added) == 0 && len(removed) == 0 {
			return nil
		}
		sort.Strings(added)
		sort.Strings(removed)

		at := when.UTC()
		events := make([]scopeChange, 0, len(added)+len(removed))
		for _, id := range removed {
			events = append(events, scopeChange{
				Date: at, IssueID: id, IssueTitle: byID[id].Title, Action: scopeRemoved,
			})
		}
		for _, id := range added {
			events = append(events, scopeChange{
				Date: at, IssueID: id, IssueTitle: byID[id].Title, Action: scopeAdded,
			})
		}
		commits = append(commits, scopeCommit{when: at, order: len(commits), events: events})
		return nil
	})
	if err != nil && !errors.Is(err, storer.ErrStop) {
		return nil, err
	}
	if len(commits) == 0 {
		return nil, nil
	}

	// Chronological. On a tied timestamp the walk's newest-first order is
	// reversed, exactly as bv does.
	sort.Slice(commits, func(i, j int) bool {
		if !commits[i].when.Equal(commits[j].when) {
			return commits[i].when.Before(commits[j].when)
		}
		return commits[i].order > commits[j].order
	})
	var out []scopeChange
	for _, c := range commits {
		out = append(out, c.events...)
	}
	return out, nil
}

// sprintAt reads one sprint's bead ids from the sprint file at a commit.
//
// The second result is false when the file or the sprint is absent there —
// bv sees no old or new line in that case, and reports nothing.
func sprintAt(commit *object.Commit, file, id string) ([]string, bool, error) {
	tree, err := commit.Tree()
	if err != nil {
		return nil, false, err
	}
	entry, err := tree.File(file)
	if err != nil {
		return nil, false, nil
	}
	contents, err := entry.Contents()
	if err != nil {
		return nil, false, err
	}

	var found []string
	have := false
	scanner := bufio.NewScanner(strings.NewReader(contents))
	// A sprint line can carry a long bead list; bv allows 10 MB.
	scanner.Buffer(make([]byte, 64*1024), 10*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		// bv only reads lines that open a JSON object.
		if !strings.HasPrefix(line, "{") {
			continue
		}
		var snap struct {
			ID      string   `json:"id"`
			BeadIDs []string `json:"bead_ids"`
		}
		if json.Unmarshal([]byte(line), &snap) != nil || snap.ID != id {
			continue
		}
		// The last line naming the sprint wins, as the last hunk line does
		// in bv.
		found, have = snap.BeadIDs, true
	}
	if err := scanner.Err(); err != nil {
		return nil, false, err
	}
	return found, have, nil
}

// setDifference is the ids in a but not in b, in a's order — bv's helper,
// blank ids skipped.
func setDifference(a, b []string) []string {
	if len(a) == 0 {
		return nil
	}
	inB := make(map[string]bool, len(b))
	for _, v := range b {
		inB[v] = true
	}
	var out []string
	for _, v := range a {
		if v != "" && !inB[v] {
			out = append(out, v)
		}
	}
	return out
}
