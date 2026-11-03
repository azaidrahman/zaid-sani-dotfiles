package bb

import (
	"reflect"
	"testing"
)

func TestParseDetails(t *testing.T) {
	d, err := ParseDetails(fixture(t, "pr.json"), fixture(t, "checks.json"), fixture(t, "diffstat.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(d.ApprovedBy, []string{"Ana"}) {
		t.Errorf("ApprovedBy = %v", d.ApprovedBy)
	}
	if !reflect.DeepEqual(d.Reviewers, []string{"Cy"}) {
		t.Errorf("Reviewers = %v", d.Reviewers)
	}
	if !reflect.DeepEqual(d.Failing, []string{"approvals 0/1"}) {
		t.Errorf("Failing = %v", d.Failing)
	}
	if d.Merge != "Can merge" || d.GitStatus != "PASSED" {
		t.Errorf("Merge = %q, GitStatus = %q", d.Merge, d.GitStatus)
	}
	if want := (File{Status: "M", Added: 12, Removed: 3, Path: "src/a.go"}); len(d.Files) != 1 || d.Files[0] != want {
		t.Errorf("Files = %v; want [%v]", d.Files, want)
	}
	if d.Updated != "2026-03-02 10:15" || d.Comments != 3 || d.Tasks != 1 || !d.Draft || d.Author != "Ben" ||
		d.Src != "feat-a" || d.Dst != "main" || d.State != "OPEN" || d.Description != "Line one.\nLine two." {
		t.Errorf("fields are wrong: %+v", d)
	}

	// A checks or diffstat payload of the wrong shape is not an error.
	d, err = ParseDetails(fixture(t, "pr.json"), []byte(`{"oops":1}`), []byte(`"x"`))
	if err != nil {
		t.Fatalf("bad checks and diffstat: %v", err)
	}
	if d.Merge != "unknown" || d.Failing != nil || d.Files != nil || d.Title != "Add parser" {
		t.Errorf("bad checks and diffstat: Merge=%q Failing=%v Files=%v Title=%q", d.Merge, d.Failing, d.Files, d.Title)
	}

	// A failed git check, and no git check.
	for _, c := range []struct{ checks, merge, status string }{
		{`[{"type": "git_mergeability_check", "status": "FAILED", "reason": "Conflicts"}]`, "Conflicts", "FAILED"},
		{`[{"type": "default_reviewer_approvals", "status": "FAILED"}]`, "unknown", ""},
	} {
		d, err := ParseDetails(fixture(t, "pr.json"), []byte(c.checks), nil)
		if err != nil {
			t.Fatal(err)
		}
		if d.Merge != c.merge || d.GitStatus != c.status {
			t.Errorf("checks %s: Merge = %q, GitStatus = %q; want %q, %q", c.checks, d.Merge, d.GitStatus, c.merge, c.status)
		}
	}
}

func TestParseActivity(t *testing.T) {
	ev, err := ParseActivity(fixture(t, "activity.json"))
	if err != nil {
		t.Fatal(err)
	}
	want := []Event{
		{Time: "2026-03-01 10:00", Who: "Ben", What: "opened"},
		{Time: "2026-03-02 12:00", Who: "Cy", What: "commented on src/a.go:42: Check this."},
		{Time: "2026-03-03 09:00", Who: "Ana", What: "approved"},
	}
	if !reflect.DeepEqual(ev, want) {
		t.Errorf("got %+v; want %+v", ev, want)
	}
}

func TestParseCommits(t *testing.T) {
	const full = "0123456789abcdef0123456789abcdef01234567"
	raw := `[{"hash": "` + full + `", "date": "2026-03-02T10:15:00+00:00",
		"message": "Add the parser\n\nIt reads the JSON.\n", "author": {"raw": "Ben Tester <ben@example.com>"}}]`
	got, err := ParseCommits([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	want := []Commit{{Hash: "01234567", Full: full, Date: "2026-03-02 10:15", Who: "Ben Tester",
		Message: "Add the parser\n\nIt reads the JSON."}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v; want %+v", got, want)
	}
}
