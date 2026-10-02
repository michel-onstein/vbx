package engine

// Custom bead-id patterns: bv's --id-pattern, and the app's default derived
// from the workspace's id prefix (vbx-znj, ADR-027).
//
// bv's explicit-id strategy and its orphan detector recognise only ids with a
// numeric suffix (`[A-Za-z]+-\d+` after a keyword, an uppercase PROJECT-123).
// A br-minted id such as vbx-8ou is neither, so a commit naming one is not
// linked unless a pattern for it is registered. bv registers them with
// correlation.SetCustomIDPatterns, once, at startup — a package global. One
// engine process serves several sessions (the app opens a window per
// workspace), each with its own patterns, so the global is set per use under
// idPatternsMu and put back afterwards; see withIDPatterns.

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/qjam/vbx/engine/correlation"
	"gopkg.in/yaml.v3"
)

// idPatternsMu serialises every use of the correlation package's
// process-global custom id patterns.
var idPatternsMu sync.Mutex

// compileIDPatterns compiles bv's --id-pattern values, failing on the first
// that does not compile with bv's own text (cmd/bv/main.go), which vbx-cli
// prints as bv does before exiting 2.
func compileIDPatterns(raw []string) ([]*regexp.Regexp, error) {
	compiled := make([]*regexp.Regexp, 0, len(raw))
	for _, p := range raw {
		re, err := regexp.Compile(p)
		if err != nil {
			return nil, fmt.Errorf("Invalid --id-pattern %q: %v", p, err)
		}
		compiled = append(compiled, re)
	}
	return compiled, nil
}

// prefixIDPattern is the pattern the app registers for an id prefix: the
// shape br mints, `<prefix>-<base36 token>`, with any `.N` child suffixes.
// Capture group 1 is the id, as bv's patterns expect.
func prefixIDPattern(prefix string) string {
	return `\b(` + regexp.QuoteMeta(prefix) + `-[0-9a-z]+(?:\.[0-9]+)*)\b`
}

// beadsConfig is the part of `.beads/config.yaml` the prefix default reads.
type beadsConfig struct {
	IssuePrefix string `yaml:"issue_prefix"`
}

// issuePrefix reads `issue_prefix` from a beads directory's config.yaml, or
// "" when the file is absent, unreadable or does not set it.
func issuePrefix(beadsDir string) string {
	raw, err := os.ReadFile(filepath.Join(beadsDir, "config.yaml"))
	if err != nil {
		return ""
	}
	var cfg beadsConfig
	if yaml.Unmarshal(raw, &cfg) != nil {
		return ""
	}
	return strings.TrimSuffix(strings.TrimSpace(cfg.IssuePrefix), "-")
}

// idPrefixes are the id prefixes of what the session loaded: the beads
// directory's issue_prefix for a single repository, and each enabled member's
// configured prefix for a workspace. Read per request, so an edit to the
// configuration is picked up on the next one.
func (s *Session) idPrefixes() []string {
	s.mu.RLock()
	source, workspacePath, repos := s.source, s.workspacePath, s.repoLoads
	s.mu.RUnlock()

	seen := map[string]bool{}
	add := func(prefix string) {
		prefix = strings.TrimSuffix(strings.TrimSpace(prefix), "-")
		if prefix != "" {
			seen[prefix] = true
		}
	}
	if workspacePath != "" {
		for _, repo := range repos {
			if !repo.disabled {
				add(repo.Prefix)
			}
		}
	} else if source != "" {
		add(issuePrefix(filepath.Dir(source)))
	}
	prefixes := make([]string, 0, len(seen))
	for prefix := range seen {
		prefixes = append(prefixes, prefix)
	}
	sort.Strings(prefixes)
	return prefixes
}

// historyIDPatterns are the custom id patterns this session's history
// registers: the --id-pattern values it was opened with, then — for a session
// opened with IDPatternsFromPrefix, as the app opens its own — one per id
// prefix. The strings key the extraction cache, because the explicit-id
// strategy runs during extraction.
func (s *Session) historyIDPatterns() ([]string, []*regexp.Regexp) {
	raw := append([]string(nil), s.config.IDPatterns...)
	if s.config.IDPatternsFromPrefix {
		for _, prefix := range s.idPrefixes() {
			raw = append(raw, prefixIDPattern(prefix))
		}
	}
	compiled, err := compileIDPatterns(raw)
	if err != nil {
		// Open refused an invalid --id-pattern, and a prefix is quoted, so
		// this cannot happen; register nothing rather than half a set.
		return nil, nil
	}
	return raw, compiled
}

// withIDPatterns runs fn with the session's patterns registered in the
// correlation package, as bv registers --id-pattern, and restores what was
// there before. The correlator reads the global in two places: its explicit
// matcher copies the patterns when NewCorrelator builds it, and the orphan
// detector reads them while it scores. Both run inside fn.
func withIDPatterns(patterns []*regexp.Regexp, fn func()) {
	idPatternsMu.Lock()
	defer idPatternsMu.Unlock()
	previous := correlation.CustomIDPatterns()
	correlation.SetCustomIDPatterns(patterns)
	defer correlation.SetCustomIDPatterns(previous)
	fn()
}

// newCorrelator is correlation.NewCorrelator with the session's id patterns
// in its explicit matcher. The lock is held only while it is built: the
// matcher keeps its own copy, so the walk itself runs unlocked.
func (s *Session) newCorrelator(place historyPlace) *correlation.Correlator {
	_, patterns := s.historyIDPatterns()
	var c *correlation.Correlator
	withIDPatterns(patterns, func() {
		c = correlation.NewCorrelator(place.workDir, place.beadsPath)
	})
	return c
}
