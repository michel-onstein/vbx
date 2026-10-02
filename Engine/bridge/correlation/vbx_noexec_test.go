package correlation

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The whole point of this package being vbx's copy is that it starts no
// process: the App Sandbox forbids it (ADR-006, ADR-027). This reads the
// source of the package and of objgit, which answers its git calls, and fails
// on any call that could start one — so an upgrade that adds a git call
// outside gitCommand, or a new exec, is caught here rather than in a sandboxed
// app that silently loses its history.
func TestNoSourceStartsAProcess(t *testing.T) {
	forbidden := map[string]bool{
		"exec.Command": true, "exec.CommandContext": true, "exec.LookPath": true,
		"os.StartProcess": true, "syscall.Exec": true, "syscall.ForkExec": true,
	}
	for _, dir := range []string{".", "../objgit"} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			name := entry.Name()
			if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
				continue
			}
			path := filepath.Join(dir, name)
			file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			ast.Inspect(file, func(n ast.Node) bool {
				sel, ok := n.(*ast.SelectorExpr)
				if !ok {
					return true
				}
				if pkg, ok := sel.X.(*ast.Ident); ok && forbidden[pkg.Name+"."+sel.Sel.Name] {
					t.Errorf("%s calls %s.%s", path, pkg.Name, sel.Sel.Name)
				}
				return true
			})
		}
	}
}

// gitCommand is the package's one way to git, and it runs objgit, not a
// binary: with nothing on PATH, a command still answers.
func TestGitCommandRunsInProcess(t *testing.T) {
	t.Setenv("PATH", "")
	out, err := gitCommand(nil, "rev-parse", "HEAD").Output()
	if err != nil || len(strings.TrimSpace(string(out))) != 40 {
		t.Fatalf("rev-parse HEAD in this repository: %q, %v", out, err)
	}
}
