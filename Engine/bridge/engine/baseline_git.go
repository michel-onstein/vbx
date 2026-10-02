package engine

import (
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/baseline"
	"github.com/go-git/go-git/v5"
)

// The commit a baseline records (vbx-6s8).
//
// bv 0.25.2's baseline.New stamps the baseline with baseline.GetGitInfo("."):
// three `git` subprocesses — `rev-parse HEAD`, `log -1 --format=%s` and
// `rev-parse --abbrev-ref HEAD` — run in the *process's* working directory.
// For bv that is the project, because bv is run from it. For the engine it is
// not: the app's working directory is "/" or wherever it was launched from,
// so a baseline saved there recorded some other repository's commit, or none.
// And the app may not spawn processes at all (ADR-006, App Sandbox).
//
// So the engine builds the Baseline itself — the struct baseline.New builds,
// field for field — and reads the three git facts from the workspace's own
// object store with go-git. Everything else is bv's: the types, Save, Load
// and Summary.

// newWorkspaceBaseline is baseline.New (bv v0.25.2) with the git metadata read
// from the repository containing dir rather than from the process's working
// directory, and without spawning git.
func newWorkspaceBaseline(
	dir string, stats baseline.GraphStats, top baseline.TopMetrics, cycles [][]string,
	description string,
) *baseline.Baseline {
	sha, message, branch := workspaceGitInfo(dir)
	return &baseline.Baseline{
		Version:       baseline.CurrentVersion,
		CreatedAt:     time.Now(),
		CommitSHA:     sha,
		CommitMessage: message,
		Branch:        branch,
		Description:   description,
		Stats:         stats,
		TopMetrics:    top,
		Cycles:        cycles,
	}
}

// workspaceGitInfo is bv v0.25.2's baseline.GetGitInfo(dir), read from the
// object store. Like GetGitInfo it never fails: what cannot be read is empty.
//
//   - sha is `git rev-parse HEAD`: HEAD's commit, empty when the directory is
//     in no repository or HEAD is unborn.
//   - message is `git log -1 --format=%s`: the commit's subject.
//   - branch is `git rev-parse --abbrev-ref HEAD`: the branch's short name, or
//     "HEAD" when it is detached. git disambiguates a branch whose short name
//     is also a tag's as "heads/<name>"; that is not ported, and reads as the
//     bare name here.
func workspaceGitInfo(dir string) (sha, message, branch string) {
	if dir == "" {
		return "", "", ""
	}
	// DetectDotGit walks up as git does from a subdirectory, and
	// EnableDotGitCommonDir resolves HEAD in a linked worktree — see
	// openObjectStore.
	repo, err := git.PlainOpenWithOptions(dir, &git.PlainOpenOptions{
		DetectDotGit:          true,
		EnableDotGitCommonDir: true,
	})
	if err != nil {
		return "", "", ""
	}
	head, err := repo.Head()
	if err != nil {
		// An unborn HEAD: all three of git's commands fail on it.
		return "", "", ""
	}
	sha = head.Hash().String()
	if commit, err := repo.CommitObject(head.Hash()); err == nil {
		message = commitSubject(commit.Message)
	}
	if head.Name().IsBranch() {
		branch = head.Name().Short()
	} else {
		branch = "HEAD"
	}
	return sha, message, branch
}

// commitSubject is git's `%s`: the first paragraph of the message, its lines
// joined by single spaces, after any leading blank lines — and then trimmed,
// as GetGitInfo trims git's output.
func commitSubject(message string) string {
	var parts []string
	for _, line := range strings.Split(message, "\n") {
		line = strings.TrimRight(line, " \t\r\v\f")
		if line == "" {
			if len(parts) == 0 {
				continue
			}
			break
		}
		parts = append(parts, line)
	}
	return strings.TrimSpace(strings.Join(parts, " "))
}
