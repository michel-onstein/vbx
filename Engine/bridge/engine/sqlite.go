package engine

import (
	"database/sql"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	_ "modernc.org/sqlite"
)

// LoadSQLite reads a beads.db store.
//
// bv has an equivalent reader but it lives in internal/datasource, which Go
// forbids importing across module boundaries, so vbx carries its own. It is
// written to be schema-tolerant in the same way bv's is: columns that a given
// beads version does not have are simply absent from the projection rather
// than causing the whole load to fail.
//
// Every row is returned, deleted ones included, as bv's LoadIssueAuthority
// returns them: a deleted bead is a resolved blocker, and a loader that drops
// it leaves its dependents waiting on a blocker that no longer exists. What
// makes a row a tombstone is bv's rule too — its status, or a nonzero
// `tombstone` column where the schema has one. `deleted_at` alone is not it;
// bv does not read that column, and br sets both together anyway. The session
// keeps tombstones out of analysis (see readiness.go).
func LoadSQLite(path string) ([]model.Issue, error) {
	db, err := sql.Open("sqlite", sqliteReadOnlyDSN(path))
	if err != nil {
		return nil, err
	}
	defer db.Close()

	cols, err := tableColumns(db, "issues")
	if err != nil {
		return nil, fmt.Errorf("reading issues schema: %w", err)
	}
	if len(cols) == 0 {
		return nil, fmt.Errorf("%s has no issues table", path)
	}

	// Project only columns this database actually has.
	want := []string{
		"id", "title", "description", "design", "acceptance_criteria", "notes",
		"status", "priority", "issue_type", "assignee", "estimated_minutes",
		"created_at", "updated_at", "closed_at", "due_at", "defer_until",
		"external_ref", "source_repo", "compaction_level", "original_size",
		"tombstone",
	}
	var selected []string
	for _, c := range want {
		if cols[c] {
			selected = append(selected, c)
		}
	}
	if !cols["id"] || !cols["title"] {
		return nil, fmt.Errorf("%s issues table lacks id/title", path)
	}

	q := fmt.Sprintf("SELECT %s FROM issues", strings.Join(selected, ", "))

	rows, err := db.Query(q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	labels := loadLabels(db)
	deps := loadDependencies(db)
	comments := loadComments(db)

	var issues []model.Issue
	for rows.Next() {
		scan := make([]any, len(selected))
		holders := make([]sql.NullString, len(selected))
		for i := range selected {
			scan[i] = &holders[i]
		}
		if err := rows.Scan(scan...); err != nil {
			return nil, err
		}

		var it model.Issue
		for i, col := range selected {
			v := holders[i]
			if !v.Valid {
				continue
			}
			assignIssueField(&it, col, v.String)
		}
		if it.ID == "" {
			continue
		}
		if it.Status == "" {
			it.Status = model.StatusOpen
		}
		if it.IssueType == "" {
			it.IssueType = model.TypeTask
		}
		it.Labels = labels[it.ID]
		it.Dependencies = deps[it.ID]
		it.Comments = comments[it.ID]
		issues = append(issues, it)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	sort.Slice(issues, func(i, j int) bool { return issues[i].ID < issues[j].ID })
	return issues, nil
}

func sqliteReadOnlyDSN(path string) string {
	// immutable=1 avoids touching -wal/-shm, which matters because the store
	// may be concurrently owned by a running bd process.
	return "file:" + url.PathEscape(path) + "?mode=ro&immutable=1&_pragma=busy_timeout(2000)"
}

func tableColumns(db *sql.DB, table string) (map[string]bool, error) {
	rows, err := db.Query(fmt.Sprintf("PRAGMA table_info(%s)", table))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := map[string]bool{}
	for rows.Next() {
		var (
			cid         int
			name, ctype string
			notnull, pk int
			dflt        sql.NullString
		)
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			return nil, err
		}
		out[name] = true
	}
	return out, rows.Err()
}

func assignIssueField(it *model.Issue, col, v string) {
	switch col {
	case "id":
		it.ID = v
	case "title":
		it.Title = v
	case "description":
		it.Description = v
	case "design":
		it.Design = v
	case "acceptance_criteria":
		it.AcceptanceCriteria = v
	case "notes":
		it.Notes = v
	case "status":
		it.Status = model.Status(v)
	case "issue_type":
		it.IssueType = model.IssueType(v)
	case "assignee":
		it.Assignee = v
	case "source_repo":
		it.SourceRepo = v
	case "external_ref":
		s := v
		it.ExternalRef = &s
	case "priority":
		it.Priority = atoiSafe(v)
	case "compaction_level":
		it.CompactionLevel = atoiSafe(v)
	case "original_size":
		it.OriginalSize = atoiSafe(v)
	case "estimated_minutes":
		n := atoiSafe(v)
		it.EstimatedMinutes = &n
	case "created_at":
		if t, ok := parseTime(v); ok {
			it.CreatedAt = t
		}
	case "updated_at":
		if t, ok := parseTime(v); ok {
			it.UpdatedAt = t
		}
	case "closed_at":
		if t, ok := parseTime(v); ok {
			it.ClosedAt = &t
		}
	case "due_at":
		if t, ok := parseTime(v); ok {
			it.DueDate = &t
		}
	case "defer_until":
		// A future defer_until withholds the bead from the ready set, so
		// leaving it unread made a deferred bead look ready (vbx-hjz).
		if t, ok := parseTime(v); ok {
			it.DeferUntil = &t
		}
	case "tombstone":
		if atoiSafe(v) != 0 {
			it.Status = model.StatusTombstone
		}
	}
}

func atoiSafe(s string) int {
	n := 0
	neg := false
	for i, r := range s {
		if i == 0 && r == '-' {
			neg = true
			continue
		}
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	if neg {
		return -n
	}
	return n
}

// parseTime accepts the several timestamp shapes beads has written over time.
func parseTime(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	layouts := []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02 15:04:05.999999999 -0700 MST",
		"2006-01-02 15:04:05.999999-07:00",
		"2006-01-02 15:04:05",
		"2006-01-02T15:04:05",
		"2006-01-02",
	}
	for _, l := range layouts {
		if t, err := time.Parse(l, s); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

func loadLabels(db *sql.DB) map[string][]string {
	out := map[string][]string{}
	rows, err := db.Query("SELECT issue_id, label FROM labels")
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var id, label sql.NullString
		if rows.Scan(&id, &label) != nil {
			continue
		}
		if id.Valid && label.Valid && label.String != "" {
			out[id.String] = append(out[id.String], label.String)
		}
	}
	return out
}

func loadDependencies(db *sql.DB) map[string][]*model.Dependency {
	out := map[string][]*model.Dependency{}
	rows, err := db.Query("SELECT issue_id, depends_on_id, type FROM dependencies")
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var issueID, dependsOn, typ sql.NullString
		if rows.Scan(&issueID, &dependsOn, &typ) != nil {
			continue
		}
		if !issueID.Valid || !dependsOn.Valid || dependsOn.String == "" {
			continue
		}
		// An empty type means "blocks" for legacy data; preserving that is
		// load-bearing because every graph metric keys off isBlocking.
		out[issueID.String] = append(out[issueID.String], &model.Dependency{
			IssueID:     issueID.String,
			DependsOnID: dependsOn.String,
			Type:        model.DependencyType(typ.String),
		})
	}
	return out
}

func loadComments(db *sql.DB) map[string][]*model.Comment {
	out := map[string][]*model.Comment{}
	rows, err := db.Query("SELECT id, issue_id, author, text, created_at FROM comments")
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var id, issueID, author, text, created sql.NullString
		if rows.Scan(&id, &issueID, &author, &text, &created) != nil {
			continue
		}
		if !issueID.Valid {
			continue
		}
		c := &model.Comment{
			ID:      id.String,
			IssueID: issueID.String,
			Author:  author.String,
			Text:    text.String,
		}
		if t, ok := parseTime(created.String); ok {
			c.CreatedAt = t
		}
		out[issueID.String] = append(out[issueID.String], c)
	}
	return out
}
