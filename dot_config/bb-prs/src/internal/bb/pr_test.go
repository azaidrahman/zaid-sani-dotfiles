package bb

import (
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestParseRemote(t *testing.T) {
	tests := []struct {
		url  string
		want string
		ok   bool
	}{
		{"https://someone@bitbucket.org/ws/repo.git", "ws/repo", true},
		{"https://bitbucket.org/ws/repo", "ws/repo", true},
		{"git@bitbucket.org:ws/repo.git", "ws/repo", true},
		{"git@github.com:owner/repo.git", "", false},
	}
	for _, tc := range tests {
		got, ok := ParseRemote(tc.url)
		if got != tc.want || ok != tc.ok {
			t.Errorf("ParseRemote(%q) = %q, %v; want %q, %v", tc.url, got, ok, tc.want, tc.ok)
		}
	}
}

func roles(prs []PR) string {
	var out []string
	for _, p := range prs {
		out = append(out, fmt.Sprintf("%s %s", p.Key(), p.Role))
	}
	return strings.Join(out, ", ")
}

func TestMergeOpen(t *testing.T) {
	prs, err := MergeOpen(fixture(t, "query.json"), fixture(t, "reviewer.json"), fixture(t, "author.json"), "ws/cur")
	if err != nil {
		t.Fatal(err)
	}
	want := "ws/cur#10 open, ws/cur#11 mine, ws/cur#12 review, ws/other#5 review, ws/zzz#7 mine"
	if got := roles(prs); got != want {
		t.Errorf("roles = %q; want %q", got, want)
	}
	first := prs[0]
	if first.Src != "feat-a" || first.Dst != "main" || first.Author != "Ana" || first.Title != "t10" ||
		first.URL != "https://bitbucket.org/ws/cur/pull-requests/10" || !first.Draft {
		t.Errorf("fields of ws/cur#10 are wrong: %+v", first)
	}
	if want := time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC); !first.Sent.Equal(want) {
		t.Errorf("Sent = %v; want %v", first.Sent, want)
	}
	if first.UpdatedRaw != "2026-03-02T10:00:00+00:00" {
		t.Errorf("UpdatedRaw = %q", first.UpdatedRaw)
	}

	none, err := MergeOpen(nil, nil, nil, "ws/cur")
	if err != nil || len(none) != 0 {
		t.Errorf("empty inputs: got %v, %v; want no PRs and no error", none, err)
	}
}

func TestMergeClosed(t *testing.T) {
	prs, err := MergeClosed(fixture(t, "merged.json"), fixture(t, "declined.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := roles(prs), "ws/cur#1 merged, ws/cur#2 declined"; got != want {
		t.Errorf("roles = %q; want %q", got, want)
	}
}

func TestSort(t *testing.T) {
	mk := func(repo string, id int, sent, updated int64) PR {
		return PR{Repo: repo, ID: id, Role: Open, Sent: time.Unix(sent, 0), Updated: time.Unix(updated, 0)}
	}
	data := func() []PR {
		return []PR{mk("ws/b", 5, 300, 1), mk("ws/a", 9, 100, 3), mk("ws/cur", 2, 200, 2), mk("ws/cur", 4, 400, 4)}
	}
	tests := []struct {
		name  string
		list  string
		order Order
		want  []int
	}{
		{"open oldest", "open", Oldest, []int{9, 2, 5, 4}},
		{"open newest", "open", Newest, []int{4, 5, 2, 9}},
		{"open by repo", "open", ByRepo, []int{4, 2, 9, 5}},
		{"closed", "closed", Oldest, []int{4, 9, 2, 5}},
	}
	for _, tc := range tests {
		prs := data()
		Sort(prs, tc.list, tc.order, "ws/cur")
		var got []int
		for _, p := range prs {
			got = append(got, p.ID)
		}
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s: got %v; want %v", tc.name, got, tc.want)
		}
	}
}

func TestAge(t *testing.T) {
	tests := []struct {
		d    time.Duration
		want string
	}{
		{59 * time.Second, "0m"},
		{5 * time.Minute, "5m"},
		{3 * time.Hour, "3h"},
		{12 * 24 * time.Hour, "12d"},
	}
	for _, tc := range tests {
		if got := Age(tc.d); got != tc.want {
			t.Errorf("Age(%v) = %q; want %q", tc.d, got, tc.want)
		}
	}
}
