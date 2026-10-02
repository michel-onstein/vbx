package engine

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// Export hooks: bv's .bv/hooks.yaml, run around a report export_report
// writes, only when the session was opened with ExportHooks (vbx-uos).

type hookReportShape struct {
	reportShape
	HookOutput string `json:"hook_output"`
	HookFailed bool   `json:"hook_failed"`
}

// hookDurations matches the run time bv's summary prints after each
// successful hook, the one part of the output that is not deterministic.
var hookDurations = regexp.MustCompile(`\((?:[0-9.]+(?:ns|µs|ms|h|m|s))+\)`)

// exportWithHooks writes hooksYAML (when not empty) into a fixture workspace,
// opens it with exportHooks, and exports to a file beside it.
func exportWithHooks(t *testing.T, exportHooks bool, hooksYAML string) (hookReportShape, string) {
	t.Helper()
	setClock(t, readinessClock)
	dir := newFixtureWorkspace(t)
	if hooksYAML != "" {
		writeFile(t, filepath.Join(dir, ".bv", "hooks.yaml"), hooksYAML)
	}
	s, err := Open(OpenConfig{Path: dir, ExportHooks: exportHooks})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	out := filepath.Join(dir, "report.md")
	r := call[hookReportShape](t, s, "export_report", map[string]any{
		"path": out, "hooks_dir": dir,
	})
	return r, out
}

func readMarker(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("marker %s: %v", path, err)
	}
	return string(data)
}

// The pre-export hook runs before the file exists and the post-export hook
// after, each with bv's BV_* context, a hook env entry expanded from it, and
// the summary printed as bv prints it.
func TestReportHooksRunAroundTheWrite(t *testing.T) {
	t.Setenv("PARITY_SECRET_TOKEN", "hunter2")
	const before = `if [ -e "$BV_EXPORT_PATH" ]; then echo present; else echo absent; fi > "$BV_EXPORT_PATH.pre"; ` +
		`printf "%s|%s|%s|%s|%s|%s\n" "$BV_EXPORT_FORMAT" "$BV_ISSUE_COUNT" "$BV_TIMESTAMP" "$GREETING" "$PARITY_SECRET_TOKEN" "$REGRANTED" >> "$BV_EXPORT_PATH.pre"`
	r, out := exportWithHooks(t, true, `hooks:
  pre-export:
    - name: before
      command: '`+before+`'
      env:
        GREETING: "hello ${BV_ISSUE_COUNT}"
        REGRANTED: "${PARITY_SECRET_TOKEN}"
  post-export:
    - command: 'wc -c < "$BV_EXPORT_PATH" | tr -d " " > "$BV_EXPORT_PATH.post"'
`)
	if r.HookFailed || r.Path != out {
		t.Fatalf("failed=%v path=%q, want a written report", r.HookFailed, r.Path)
	}
	// The ambient token is scrubbed; the hook's own env re-grants it.
	want := "absent\nmarkdown|5|2026-08-29T10:40:00Z|hello 5||hunter2\n"
	if got := readMarker(t, out+".pre"); got != want {
		t.Errorf("pre marker = %q, want %q", got, want)
	}
	if got := strings.TrimSpace(readMarker(t, out+".post")); got != strconv.Itoa(r.Bytes) {
		t.Errorf("post marker = %q, want the report's %d bytes", got, r.Bytes)
	}
	wantOutput := "  → Running pre-export hook \"before\": " + before + "\n" +
		"  → Running post-export hook \"post-export-1\": wc -c < \"$BV_EXPORT_PATH\" | tr -d \" \" > \"$BV_EXPORT_PATH.post\"\n" +
		"Hook execution: 2 succeeded, 0 failed\n" +
		"  [OK] before (<d>)\n" +
		"  [OK] post-export-1 (<d>)\n" +
		"\n"
	if got := hookDurations.ReplaceAllString(r.HookOutput, "(<d>)"); got != wantOutput {
		t.Errorf("hook output =\n%s\nwant\n%s", got, wantOutput)
	}
}

// A failing pre-export hook aborts: nothing is written, no summary is
// printed, and the failure is bv's exit 1.
func TestReportPreExportFailureWritesNothing(t *testing.T) {
	r, out := exportWithHooks(t, true, `hooks:
  pre-export:
    - name: gate
      command: 'echo nope >&2; exit 3'
  post-export:
    - command: 'touch "$BV_EXPORT_PATH.post"'
`)
	if !r.HookFailed || r.Path != "" {
		t.Fatalf("failed=%v path=%q, want a failure and no write", r.HookFailed, r.Path)
	}
	for _, path := range []string{out, out + ".post"} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("%s exists; a failed pre-export hook must stop the export", path)
		}
	}
	want := "  → Running pre-export hook \"gate\": echo nope >&2; exit 3\n" +
		"Error: pre-export hook failed: pre-export hook \"gate\" failed: exit status 3\n"
	if r.HookOutput != want {
		t.Errorf("hook output = %q, want %q", r.HookOutput, want)
	}
}

// A failing post-export hook is reported in the summary; it fails the export
// only when it says `on_error: fail`, and then after the file is written.
func TestReportPostExportFailurePolicy(t *testing.T) {
	r, out := exportWithHooks(t, true, `hooks:
  post-export:
    - name: tolerated
      command: 'echo soft >&2; exit 1'
    - name: strict
      command: 'echo hard >&2; exit 2'
      on_error: fail
`)
	if !r.HookFailed || r.Path != out {
		t.Fatalf("failed=%v path=%q, want a failure after the write", r.HookFailed, r.Path)
	}
	if _, err := os.Stat(out); err != nil {
		t.Errorf("report not written: %v", err)
	}
	want := "  → Running post-export hook \"tolerated\": echo soft >&2; exit 1\n" +
		"  → Running post-export hook \"strict\": echo hard >&2; exit 2\n" +
		"Hook execution: 0 succeeded, 2 failed\n" +
		"  [FAIL] tolerated: exit status 1\n" +
		"         stderr: soft\n" +
		"  [FAIL] strict: exit status 2\n" +
		"         stderr: hard\n" +
		"\n" +
		"Error: post-export hook \"strict\" failed: exit status 2 (export written to " + out + ")\n"
	if r.HookOutput != want {
		t.Errorf("hook output =\n%s\nwant\n%s", r.HookOutput, want)
	}

	// The same failure, tolerated: reported, and the export succeeds.
	r, _ = exportWithHooks(t, true, `hooks:
  post-export:
    - name: tolerated
      command: 'exit 1'
`)
	if r.HookFailed || !strings.Contains(r.HookOutput, "  [FAIL] tolerated: exit status 1\n") {
		t.Errorf("failed=%v output=%q, want a reported but tolerated failure", r.HookFailed, r.HookOutput)
	}
}

// A hook file that does not parse is bv's warning, and the export goes on.
func TestReportUnreadableHooksWarn(t *testing.T) {
	r, out := exportWithHooks(t, true, "hooks: [not, a, map\n")
	if r.HookFailed || r.Path != out {
		t.Fatalf("failed=%v path=%q, want the export to go on", r.HookFailed, r.Path)
	}
	if !strings.HasPrefix(r.HookOutput, "Warning: failed to load hooks: parsing ") {
		t.Errorf("hook output = %q, want bv's load warning", r.HookOutput)
	}
}

// The app's session never runs a hook: a configured one is not even read,
// because running it is a subprocess the App Sandbox forbids. This is also
// --no-hooks, which is vbx-cli opening without ExportHooks.
func TestReportHooksNeedTheSessionOption(t *testing.T) {
	r, out := exportWithHooks(t, false, `hooks:
  pre-export:
    - command: 'touch "$BV_EXPORT_PATH.pre"; exit 1'
`)
	if r.HookFailed || r.HookOutput != "" || r.Path != out {
		t.Fatalf("failed=%v output=%q path=%q, want a plain export", r.HookFailed, r.HookOutput, r.Path)
	}
	if _, err := os.Stat(out + ".pre"); !os.IsNotExist(err) {
		t.Error("a hook ran in a session opened without ExportHooks")
	}
}

// No hook file is no hooks, and no output at all.
func TestReportWithoutHookFileIsSilent(t *testing.T) {
	r, out := exportWithHooks(t, true, "")
	if r.HookFailed || r.HookOutput != "" || r.Path != out {
		t.Fatalf("failed=%v output=%q path=%q, want a plain export", r.HookFailed, r.HookOutput, r.Path)
	}
}

// Content-only exports — the app's, with no path — never run a hook.
func TestReportWithoutPathRunsNoHooks(t *testing.T) {
	setClock(t, readinessClock)
	dir := newFixtureWorkspace(t)
	writeFile(t, filepath.Join(dir, ".bv", "hooks.yaml"), `hooks:
  pre-export:
    - command: 'touch "`+filepath.Join(dir, "ran")+`"'
`)
	s, err := Open(OpenConfig{Path: dir, ExportHooks: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	r := call[hookReportShape](t, s, "export_report", map[string]any{"hooks_dir": dir})
	if r.HookOutput != "" || r.Content == "" {
		t.Errorf("output=%q, want content and no hooks", r.HookOutput)
	}
	if _, err := os.Stat(filepath.Join(dir, "ran")); !os.IsNotExist(err) {
		t.Error("a hook ran for an export with no path")
	}
}
