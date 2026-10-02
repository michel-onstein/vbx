package objgit

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/go-git/go-git/v5/plumbing"
)

// revParse answers `git rev-parse <rev>`: the full hash and a newline.
func (r *repo) revParse(args []string, stdout io.Writer) error {
	if len(args) != 1 || strings.HasPrefix(args[0], "-") {
		return unsupported("rev-parse %s", strings.Join(args, " "))
	}
	h, err := r.git.ResolveRevision(plumbing.Revision(args[0]))
	if err != nil {
		return fatal("ambiguous argument '%s': unknown revision or path not in the working tree.", args[0])
	}
	_, err = fmt.Fprintf(stdout, "%s\n", h)
	return err
}

// catFile answers `git cat-file -s <object>` and `git cat-file --batch`.
func (r *repo) catFile(ctx context.Context, args []string, stdin io.Reader, stdout io.Writer) error {
	switch {
	case len(args) == 2 && args[0] == "-s":
		obj, err := r.lookup(args[1])
		if err != nil || obj == nil {
			return fatal("Not a valid object name %s", args[1])
		}
		_, err = fmt.Fprintf(stdout, "%d\n", obj.Size())
		return err
	case len(args) == 1 && args[0] == "--batch":
		return r.catFileBatch(ctx, stdin, stdout)
	}
	return unsupported("cat-file %s", strings.Join(args, " "))
}

// catFileBatch reads object names a line at a time and answers each as it
// arrives — "<hash> <type> <size>", the content and a newline, or "<name>
// missing" — because bv's reader writes one name and waits for its answer.
func (r *repo) catFileBatch(ctx context.Context, stdin io.Reader, stdout io.Writer) error {
	if stdin == nil {
		return nil
	}
	in := bufio.NewReader(stdin)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		line, err := in.ReadString('\n')
		if line == "" && err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		name := strings.TrimSuffix(line, "\n")
		obj, lookupErr := r.lookup(name)
		if lookupErr != nil || obj == nil {
			if _, err := fmt.Fprintf(stdout, "%s missing\n", name); err != nil {
				return err
			}
			continue
		}
		if err := writeObject(stdout, obj); err != nil {
			return err
		}
	}
}

func writeObject(w io.Writer, obj plumbing.EncodedObject) error {
	rd, err := obj.Reader()
	if err != nil {
		return err
	}
	defer rd.Close()
	if _, err := fmt.Fprintf(w, "%s %s %d\n", obj.Hash(), obj.Type(), obj.Size()); err != nil {
		return err
	}
	if _, err := io.Copy(w, rd); err != nil {
		return err
	}
	_, err = io.WriteString(w, "\n")
	return err
}

// lookup finds an object by full hash, `<rev>:<path>`, or a revision. nil
// with no error means it does not exist.
func (r *repo) lookup(name string) (plumbing.EncodedObject, error) {
	if len(name) == 40 && isHexString(name) {
		obj, err := r.git.Storer.EncodedObject(plumbing.AnyObject, plumbing.NewHash(name))
		if err == plumbing.ErrObjectNotFound {
			return nil, nil
		}
		return obj, err
	}
	if rev, p, ok := strings.Cut(name, ":"); ok {
		h, err := r.git.ResolveRevision(plumbing.Revision(rev))
		if err != nil {
			return nil, nil
		}
		c, err := r.git.CommitObject(*h)
		if err != nil {
			return nil, nil
		}
		tree, err := c.Tree()
		if err != nil {
			return nil, err
		}
		entry, err := tree.FindEntry(p)
		if err != nil {
			return nil, nil
		}
		obj, err := r.git.Storer.EncodedObject(plumbing.AnyObject, entry.Hash)
		if err == plumbing.ErrObjectNotFound {
			return nil, nil
		}
		return obj, err
	}
	h, err := r.git.ResolveRevision(plumbing.Revision(name))
	if err != nil {
		return nil, nil
	}
	obj, err := r.git.Storer.EncodedObject(plumbing.AnyObject, *h)
	if err == plumbing.ErrObjectNotFound {
		return nil, nil
	}
	return obj, err
}

func isHexString(s string) bool {
	for i := 0; i < len(s); i++ {
		if !isHex(s[i]) {
			return false
		}
	}
	return true
}
