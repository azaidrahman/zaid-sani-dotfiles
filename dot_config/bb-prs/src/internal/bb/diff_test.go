package bb

import (
	"reflect"
	"testing"
)

func TestParseDiff(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want []FileDiff
	}{
		{
			name: "modified",
			raw: "junk before the first file\n" +
				"diff --git a/src/a.go b/src/a.go\n" +
				"index 1111111..2222222 100644\n" +
				"--- a/src/a.go\n" +
				"+++ b/src/a.go\n" +
				"@@ -1,3 +1,3 @@\n" +
				" package a\n" +
				"-var x = 1\n" +
				"+var x = 2\n" +
				"@@ -10,2 +10,3 @@ func f() {\n" +
				" \ta()\n" +
				"+-- not a header\n",
			want: []FileDiff{{Path: "src/a.go", Status: "M", Added: 2, Removed: 1, Lines: []string{
				"@@ -1,3 +1,3 @@", " package a", "-var x = 1", "+var x = 2",
				"@@ -10,2 +10,3 @@ func f() {", " \ta()", "+-- not a header",
			}}},
		},
		{
			name: "new file",
			raw: "diff --git a/new.txt b/new.txt\n" +
				"new file mode 100644\n" +
				"index 0000000..3333333\n" +
				"--- /dev/null\n" +
				"+++ b/new.txt\n" +
				"@@ -0,0 +1,2 @@\n" +
				"+one\n" +
				"+two\n",
			want: []FileDiff{{Path: "new.txt", Status: "A", Added: 2, Lines: []string{"@@ -0,0 +1,2 @@", "+one", "+two"}}},
		},
		{
			name: "deleted file",
			raw: "diff --git a/old.txt b/old.txt\n" +
				"deleted file mode 100644\n" +
				"index 4444444..0000000\n" +
				"--- a/old.txt\n" +
				"+++ /dev/null\n" +
				"@@ -1 +0,0 @@\n" +
				"-gone\n",
			want: []FileDiff{{Path: "old.txt", Status: "D", Removed: 1, Lines: []string{"@@ -1 +0,0 @@", "-gone"}}},
		},
		{
			// Git puts a tab after a path with a space in the --- and +++ lines.
			name: "rename",
			raw: "diff --git a/x/old name.go b/x/new name.go\n" +
				"similarity index 90%\n" +
				"rename from x/old name.go\n" +
				"rename to x/new name.go\n" +
				"index 5555555..6666666 100644\n" +
				"--- a/x/old name.go\t\n" +
				"+++ b/x/new name.go\t\n" +
				"@@ -1 +1 @@\n" +
				"-a\n" +
				"+b\n",
			want: []FileDiff{{Path: "x/new name.go", OldPath: "x/old name.go", Status: "R", Added: 1, Removed: 1,
				Lines: []string{"@@ -1 +1 @@", "-a", "+b"}}},
		},
		{
			name: "binary",
			raw: "diff --git a/img.png b/img.png\n" +
				"index 7777777..8888888 100644\n" +
				"Binary files a/img.png and b/img.png differ\n",
			want: []FileDiff{{Path: "img.png", Status: "M", Binary: true}},
		},
		{
			name: "no newline at the end",
			raw: "diff --git a/n.txt b/n.txt\n" +
				"--- a/n.txt\n" +
				"+++ b/n.txt\n" +
				"@@ -1 +1 @@\n" +
				"-old\n" +
				"\\ No newline at end of file\n" +
				"+new\n" +
				"\\ No newline at end of file\n",
			want: []FileDiff{{Path: "n.txt", Status: "M", Added: 1, Removed: 1, Lines: []string{
				"@@ -1 +1 @@", "-old", `\ No newline at end of file`, "+new", `\ No newline at end of file`,
			}}},
		},
		{
			name: "CRLF line",
			raw:  "diff --git a/w.txt b/w.txt\r\n--- a/w.txt\r\n+++ b/w.txt\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n",
			want: []FileDiff{{Path: "w.txt", Status: "M", Added: 1, Removed: 1, Lines: []string{"@@ -1 +1 @@", "-a", "+b"}}},
		},
		{
			name: "no diff",
			raw:  "ok\nnothing here\n",
			want: nil,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := ParseDiff([]byte(c.raw)); !reflect.DeepEqual(got, c.want) {
				t.Errorf("ParseDiff =\n%+v\nwant\n%+v", got, c.want)
			}
		})
	}
}
