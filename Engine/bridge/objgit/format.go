package objgit

import (
	"strconv"
	"strings"
	"time"

	"github.com/go-git/go-git/v5/plumbing/object"
)

// placeholders git's --format understands that this package expands. The
// set is exactly what bv's correlation package asks for, plus the trivial
// escapes; any other placeholder is refused rather than printed literally.
const strictISO = "2006-01-02T15:04:05Z07:00"

// validateFormat checks a --format string before any output is written, so
// an unsupported placeholder fails the command instead of half-printing it.
func validateFormat(format string) error {
	_, err := expand(format, nil)
	return err
}

// expand renders one commit through a git pretty format. A nil commit only
// validates the format.
func expand(format string, c *object.Commit) (string, error) {
	var b strings.Builder
	for i := 0; i < len(format); i++ {
		ch := format[i]
		if ch != '%' {
			b.WriteByte(ch)
			continue
		}
		rest := format[i+1:]
		switch {
		case strings.HasPrefix(rest, "%"):
			b.WriteByte('%')
			i++
		case strings.HasPrefix(rest, "n"):
			b.WriteByte('\n')
			i++
		case strings.HasPrefix(rest, "x") && len(rest) >= 3 && isHex(rest[1]) && isHex(rest[2]):
			v, _ := strconv.ParseUint(rest[1:3], 16, 8)
			b.WriteByte(byte(v))
			i += 3
		case strings.HasPrefix(rest, "H"):
			if c != nil {
				b.WriteString(c.Hash.String())
			}
			i++
		case strings.HasPrefix(rest, "aI"):
			if c != nil {
				b.WriteString(c.Author.When.Format(strictISO))
			}
			i += 2
		case strings.HasPrefix(rest, "cI"):
			if c != nil {
				b.WriteString(c.Committer.When.Format(strictISO))
			}
			i += 2
		case strings.HasPrefix(rest, "an"):
			if c != nil {
				b.WriteString(c.Author.Name)
			}
			i += 2
		case strings.HasPrefix(rest, "ae"):
			if c != nil {
				b.WriteString(c.Author.Email)
			}
			i += 2
		case strings.HasPrefix(rest, "s"):
			if c != nil {
				subject, _ := splitMessage(c.Message)
				b.WriteString(subject)
			}
			i++
		case strings.HasPrefix(rest, "b"):
			if c != nil {
				_, body := splitMessage(c.Message)
				b.WriteString(body)
			}
			i++
		default:
			end := len(rest)
			if end > 2 {
				end = 2
			}
			return "", unsupported("--format placeholder %%%s", rest[:end])
		}
	}
	return b.String(), nil
}

func isHex(c byte) bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// splitMessage returns git's %s and %b for a raw commit message.
//
// The subject is the first paragraph — leading blank lines skipped, each line
// stripped of trailing whitespace, the lines joined by single spaces. The body
// is everything after the blank lines that follow it, verbatim, final newline
// included. That is pretty.c's format_subject and body_off.
func splitMessage(message string) (subject, body string) {
	lines := splitKeepEnds(message)
	i := 0
	for i < len(lines) && isBlank(lines[i]) {
		i++
	}
	var parts []string
	for i < len(lines) && !isBlank(lines[i]) {
		parts = append(parts, strings.TrimRight(lines[i], " \t\n\r\v\f"))
		i++
	}
	for i < len(lines) && isBlank(lines[i]) {
		i++
	}
	return strings.Join(parts, " "), strings.Join(lines[i:], "")
}

// splitKeepEnds splits text into lines, each keeping its "\n".
func splitKeepEnds(text string) []string {
	var lines []string
	for len(text) > 0 {
		nl := strings.IndexByte(text, '\n')
		if nl < 0 {
			lines = append(lines, text)
			break
		}
		lines = append(lines, text[:nl+1])
		text = text[nl+1:]
	}
	return lines
}

func isBlank(line string) bool {
	return strings.TrimRight(line, " \t\n\r\v\f") == ""
}

// quotePath renders a path as git prints it outside -z mode: bare when it is
// plain, otherwise C-quoted with git's escapes (quote.c's quote_c_style). With
// core.quotePath on, every byte above 0x7f is octal-escaped too.
func (r *repo) quotePathName(path string) string {
	needs := false
	for i := 0; i < len(path); i++ {
		if r.mustQuote(path[i]) {
			needs = true
			break
		}
	}
	if !needs {
		return path
	}
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(path); i++ {
		c := path[i]
		if !r.mustQuote(c) {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('\\')
		switch c {
		case '\a':
			b.WriteByte('a')
		case '\b':
			b.WriteByte('b')
		case '\t':
			b.WriteByte('t')
		case '\n':
			b.WriteByte('n')
		case '\v':
			b.WriteByte('v')
		case '\f':
			b.WriteByte('f')
		case '\r':
			b.WriteByte('r')
		case '"':
			b.WriteByte('"')
		case '\\':
			b.WriteByte('\\')
		default:
			b.WriteByte('0' + (c>>6)&7)
			b.WriteByte('0' + (c>>3)&7)
			b.WriteByte('0' + c&7)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func (r *repo) mustQuote(c byte) bool {
	if c < 0x20 || c == '"' || c == '\\' || c == 0x7f {
		return true
	}
	return c >= 0x80 && r.quotePath
}

// parseTime reads a --since or --until value. bv passes RFC 3339 only;
// git's approxidate accepts far more, and a value outside RFC 3339 is refused
// rather than guessed at.
func parseTime(value string) (time.Time, error) {
	t, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return time.Time{}, unsupported("date %q (only RFC 3339 is understood)", value)
	}
	return t, nil
}
