package bb

import (
	"strconv"
	"strings"
)

// FileDiff is the diff of one file of a PR.
type FileDiff struct {
	// Path is the path of the file after the change. For a deleted file, it
	// is the path before the change. OldPath is set only for a rename.
	Path, OldPath string
	Status        string // M, A, D, or R
	// Added and Removed count the lines of the hunks that start with + and -.
	Added, Removed int
	Binary         bool
	// Lines holds the lines of the hunks, from the first "@@" line. The
	// lines have no line break at the end.
	Lines []string
}

// ParseDiff splits a unified diff from git into its files. It never fails.
// It drops the text before the first "diff --git" line. A binary file has no
// lines.
func ParseDiff(raw []byte) []FileDiff {
	text := strings.TrimSuffix(string(raw), "\n")
	if text == "" {
		return nil
	}
	var files []FileDiff
	var f *FileDiff
	var oldPath, newPath string
	inHunk := false
	done := func() {
		if f == nil {
			return
		}
		f.Path = newPath
		if f.Status == "D" || f.Path == "" {
			f.Path = oldPath
		}
		if f.Status == "R" {
			f.OldPath = oldPath
		}
		files = append(files, *f)
	}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSuffix(line, "\r")
		if rest, ok := strings.CutPrefix(line, "diff --git "); ok {
			done()
			f = &FileDiff{Status: "M"}
			oldPath, newPath = headerPaths(rest)
			inHunk = false
			continue
		}
		if f == nil {
			continue
		}
		if !inHunk && strings.HasPrefix(line, "@@") {
			inHunk = true
		}
		if inHunk {
			switch {
			case strings.HasPrefix(line, "+"):
				f.Added++
			case strings.HasPrefix(line, "-"):
				f.Removed++
			}
			f.Lines = append(f.Lines, line)
			continue
		}
		switch {
		case strings.HasPrefix(line, "new file mode"):
			f.Status = "A"
		case strings.HasPrefix(line, "deleted file mode"):
			f.Status = "D"
		case strings.HasPrefix(line, "rename from "):
			f.Status = "R"
			oldPath = unquote(strings.TrimPrefix(line, "rename from "))
		case strings.HasPrefix(line, "rename to "):
			f.Status = "R"
			newPath = unquote(strings.TrimPrefix(line, "rename to "))
		case strings.HasPrefix(line, "--- "):
			if p, ok := sidePath(line[4:], "a/"); ok {
				oldPath = p
			}
		case strings.HasPrefix(line, "+++ "):
			if p, ok := sidePath(line[4:], "b/"); ok {
				newPath = p
			}
		case strings.HasPrefix(line, "Binary files ") && strings.HasSuffix(line, " differ"),
			line == "GIT binary patch":
			f.Binary = true
		}
	}
	done()
	return files
}

// sidePath reads the path of a "---" or a "+++" line. Git puts a tab after a
// path with a space. The result is false for /dev/null.
func sidePath(s, prefix string) (string, bool) {
	s, _, _ = strings.Cut(s, "\t")
	if s == "/dev/null" {
		return "", false
	}
	return strings.TrimPrefix(unquote(s), prefix), true
}

// headerPaths reads the two paths of a "diff --git a/<old> b/<new>" line.
// The other lines of the diff can give better paths.
func headerPaths(rest string) (oldPath, newPath string) {
	if strings.HasPrefix(rest, `"`) {
		if q, err := strconv.QuotedPrefix(rest); err == nil {
			oldPath = strings.TrimPrefix(unquote(q), "a/")
			newPath = strings.TrimPrefix(unquote(strings.TrimPrefix(rest[len(q):], " ")), "b/")
			return oldPath, newPath
		}
	}
	// The usual case: the same path on the two sides, "a/P b/P".
	if n := len(rest); n%2 == 1 {
		h := n / 2
		if rest[h] == ' ' && strings.HasPrefix(rest, "a/") && strings.HasPrefix(rest[h+1:], "b/") && rest[2:h] == rest[h+3:] {
			return rest[2:h], rest[h+3:]
		}
	}
	if i := strings.Index(rest, " b/"); i >= 0 {
		return strings.TrimPrefix(rest[:i], "a/"), rest[i+3:]
	}
	return strings.TrimPrefix(rest, "a/"), ""
}

// unquote removes the quotes that git puts around a path with special
// characters, and reads the escapes in it.
func unquote(s string) string {
	if strings.HasPrefix(s, `"`) {
		if u, err := strconv.Unquote(s); err == nil {
			return u
		}
	}
	return s
}
