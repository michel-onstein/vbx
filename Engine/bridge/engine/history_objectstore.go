// Package engine — reading the object store directly.
//
// The App Sandbox cannot spawn git (ADR-006), so everything vbx reads from a
// repository's history it reads through go-git: the bead set at a revision
// (time travel), the commits that changed the beads file (the scrubber), and
// one commit's patch (the History view's diff). The correlation reports are
// bv's own correlator, whose git calls objgit answers (history.go, ADR-027).
package engine

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/storer"
)

// objectStoreExtractor reads one repository's object store.
type objectStoreExtractor struct {
	repo *git.Repository
	// beadsPath is the beads file's path relative to the repository root,
	// slash-separated as git stores it.
	beadsPath string
}

// openObjectStore locates the repository containing sourcePath.
func openObjectStore(sourcePath string) (*objectStoreExtractor, error) {
	dir := filepath.Dir(sourcePath)
	// EnableDotGitCommonDir is what makes a *linked worktree* work. There,
	// `.git` is a file pointing at `<main>/.git/worktrees/<name>`, and the
	// refs — HEAD included — live in the common directory rather than beside
	// the worktree. Without it, opening succeeds and resolving HEAD then fails
	// with "reference not found", which reads like an empty repository.
	repo, err := git.PlainOpenWithOptions(dir, &git.PlainOpenOptions{
		DetectDotGit:          true,
		EnableDotGitCommonDir: true,
	})
	if err != nil {
		return nil, fmt.Errorf("opening git repository near %s: %w", dir, err)
	}

	root, err := repositoryRoot(repo)
	if err != nil {
		return nil, err
	}

	// Both sides are resolved before comparing. On macOS a temporary
	// directory — and /tmp itself — is a symlink, and go-git reports the
	// resolved worktree root while the caller passes the unresolved path.
	// Subtracting one from the other then yields a "../../.." path that
	// matches no tree entry, which shows up as a repository whose beads file
	// is apparently never touched.
	rel, err := filepath.Rel(resolvePath(root), resolvePath(sourcePath))
	if err != nil || strings.HasPrefix(rel, "..") {
		return nil, fmt.Errorf("%s is not inside the repository at %s", sourcePath, root)
	}
	beadsPath := filepath.ToSlash(rel)

	return &objectStoreExtractor{repo: repo, beadsPath: beadsPath}, nil
}

// resolvePath follows symlinks, falling back to the input when it cannot.
//
// The fallback matters: the path may not exist yet, or may sit behind a
// directory the process cannot stat, and neither is a reason to fail outright.
func resolvePath(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return path
}

// repositoryRoot resolves the working tree's root directory.
func repositoryRoot(repo *git.Repository) (string, error) {
	tree, err := repo.Worktree()
	if err != nil {
		return "", fmt.Errorf("resolving worktree: %w", err)
	}
	return tree.Filesystem.Root(), nil
}

// revisionInfo is one point the time-travel scrubber can jump to.
type revisionInfo struct {
	SHA      string    `json:"sha"`
	ShortSHA string    `json:"short_sha"`
	Subject  string    `json:"subject"`
	Author   string    `json:"author"`
	When     time.Time `json:"when"`
}

// resolve turns a revision expression into a commit hash.
//
// go-git's resolver understands the same vocabulary git does — `HEAD~3`, a
// branch or tag name, a short SHA — so the scrubber accepts whatever the user
// would type, and the *resolved* hash is what gets reported back.
func (e *objectStoreExtractor) resolve(revision string) (plumbing.Hash, error) {
	if strings.TrimSpace(revision) == "" {
		revision = "HEAD"
	}
	hash, err := e.repo.ResolveRevision(plumbing.Revision(revision))
	if err != nil {
		return plumbing.ZeroHash, fmt.Errorf("cannot resolve %q: %w", revision, err)
	}
	return *hash, nil
}

// issuesAt reads the bead set as of one commit.
func (e *objectStoreExtractor) issuesAt(hash plumbing.Hash) ([]model.Issue, time.Time, error) {
	commit, err := e.repo.CommitObject(hash)
	if err != nil {
		return nil, time.Time{}, fmt.Errorf("reading commit %s: %w", shortHash(hash.String()), err)
	}
	tree, err := commit.Tree()
	if err != nil {
		return nil, time.Time{}, err
	}

	entry, err := tree.File(e.beadsPath)
	if err != nil {
		// The beads file not existing yet is a real answer — the workspace had
		// no beads at that revision — not a failure.
		return []model.Issue{}, commit.Author.When, nil
	}
	reader, err := entry.Reader()
	if err != nil {
		return nil, time.Time{}, err
	}
	defer reader.Close()

	issues, err := loader.ParseIssues(reader)
	if err != nil {
		return nil, time.Time{}, fmt.Errorf("parsing beads at %s: %w",
			shortHash(hash.String()), err)
	}
	return issues, commit.Author.When, nil
}

// revisions lists recent commits that changed the beads file.
//
// Only those, because a commit that did not touch it leaves the bead set
// identical — a scrubber over every commit would be mostly no-op steps.
func (e *objectStoreExtractor) revisions(ctx context.Context, limit int) ([]revisionInfo, error) {
	head, err := e.repo.Head()
	if err != nil {
		return nil, fmt.Errorf("resolving HEAD: %w", err)
	}
	if limit <= 0 {
		limit = 50
	}

	iter, err := e.repo.Log(&git.LogOptions{
		From:     head.Hash(),
		Order:    git.LogOrderCommitterTime,
		FileName: &e.beadsPath,
	})
	if err != nil {
		return nil, err
	}
	defer iter.Close()

	out := []revisionInfo{}
	err = iter.ForEach(func(commit *object.Commit) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		subject := strings.TrimSpace(commit.Message)
		if index := strings.Index(subject, "\n"); index >= 0 {
			subject = subject[:index]
		}
		out = append(out, revisionInfo{
			SHA:      commit.Hash.String(),
			ShortSHA: shortHash(commit.Hash.String()),
			Subject:  subject,
			Author:   commit.Author.Name,
			When:     commit.Author.When,
		})
		if len(out) >= limit {
			return storer.ErrStop
		}
		return nil
	})
	if err != nil && err != storer.ErrStop {
		return nil, err
	}
	return out, nil
}

// patch renders one commit's unified diff, optionally narrowed to one path.
//
// The app cannot shell out to `git diff`, and a file list with line counts
// does not answer "what actually changed". go-git already decodes the blobs
// for the line counts, so the patch text costs little more.
func (e *objectStoreExtractor) patch(
	ctx context.Context, sha string, only string,
) (string, error) {
	hash := plumbing.NewHash(sha)
	commit, err := e.repo.CommitObject(hash)
	if err != nil {
		return "", fmt.Errorf("reading commit %s: %w", shortHash(sha), err)
	}
	tree, err := commit.Tree()
	if err != nil {
		return "", err
	}

	var parentTree *object.Tree
	if commit.NumParents() > 0 {
		if parent, perr := commit.Parent(0); perr == nil {
			parentTree, _ = parent.Tree()
		}
	}

	changes, err := object.DiffTreeWithOptions(
		ctx, parentTree, tree, &object.DiffTreeOptions{DetectRenames: true})
	if err != nil {
		return "", err
	}

	if only != "" {
		filtered := object.Changes{}
		for _, change := range changes {
			if change.To.Name == only || change.From.Name == only {
				filtered = append(filtered, change)
			}
		}
		if len(filtered) == 0 {
			return "", fmt.Errorf("commit %s does not touch %s", shortHash(sha), only)
		}
		changes = filtered
	}

	result, err := changes.PatchContext(ctx)
	if err != nil {
		return "", err
	}
	return result.String(), nil
}

func shortHash(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}
