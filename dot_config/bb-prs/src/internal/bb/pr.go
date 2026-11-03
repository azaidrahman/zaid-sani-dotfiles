// Package bb turns the JSON of twg into the data that the PR picker shows.
package bb

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Role tells how the user relates to a PR. A closed PR has the role of its state.
type Role string

const (
	Mine     Role = "mine"
	Review   Role = "review"
	Open     Role = "open"
	Merged   Role = "merged"
	Declined Role = "declined"
)

// PR is one row of the list.
type PR struct {
	Repo string `json:"repo"`
	ID   int    `json:"id"`
	Role Role   `json:"role"`
	URL  string `json:"url"`
	Src  string `json:"src"`
	Dst  string `json:"dst"`
	// SrcRepo is the full name of the repo of the source branch. It is not
	// Repo for a PR from a fork. It is empty if the list did not tell it: the
	// inbox does not, and an old cache does not.
	SrcRepo string `json:"src_repo,omitempty"`
	Author  string `json:"author"`
	Title   string `json:"title"`
	Draft   bool   `json:"draft"`
	// Sent is the time of creation. Updated is the time of the last change.
	Sent    time.Time `json:"sent"`
	Updated time.Time `json:"updated"`
	// UpdatedRaw is the text of Updated, as twg gave it. A cache key uses it.
	UpdatedRaw string `json:"updated_raw"`
}

// Key returns "<repo>#<id>".
func (p PR) Key() string { return fmt.Sprintf("%s#%d", p.Repo, p.ID) }

// IsOpen is true for a PR that is not merged and not declined.
func (p PR) IsOpen() bool { return p.Role == Mine || p.Role == Review || p.Role == Open }

var remoteRe = regexp.MustCompile(`bitbucket\.org[:/]([^/]+)/([^/]+)$`)

// ParseRemote reads "<workspace>/<repo>" from the URL of a Bitbucket remote.
func ParseRemote(url string) (repo string, ok bool) {
	m := remoteRe.FindStringSubmatch(url)
	if m == nil {
		return "", false
	}
	return m[1] + "/" + strings.TrimSuffix(m[2], ".git"), true
}

// parseTime reads the first 19 characters of a time text as UTC. It ignores
// the fraction and the offset. An empty or bad text gives the zero time.
func parseTime(s string) time.Time {
	if len(s) < 19 {
		return time.Time{}
	}
	t, err := time.Parse("2006-01-02T15:04:05", s[:19])
	if err != nil {
		return time.Time{}
	}
	return t
}

// inbox is the JSON of `twg bitbucket inbox`.
type inbox struct {
	CurrentUser struct {
		UUID string `json:"uuid"`
	} `json:"currentUser"`
	Items []struct {
		ID     int    `json:"id"`
		Repo   string `json:"repo"`
		Title  string `json:"title"`
		Draft  bool   `json:"draft"`
		State  string `json:"state"`
		Link   string `json:"link"`
		Author struct {
			DisplayName string `json:"displayName"`
		} `json:"author"`
		SourceBranch      string `json:"sourceBranch"`
		DestinationBranch string `json:"destinationBranch"`
		CreatedOn         string `json:"createdOn"`
		UpdatedOn         string `json:"updatedOn"`
	} `json:"items"`
}

// queryPR is one PR of `twg bitbucket pull-requests query`.
type queryPR struct {
	ID        int    `json:"id"`
	Title     string `json:"title"`
	Draft     bool   `json:"draft"`
	State     string `json:"state"`
	CreatedOn string `json:"created_on"`
	UpdatedOn string `json:"updated_on"`
	Author    struct {
		UUID        string `json:"uuid"`
		DisplayName string `json:"display_name"`
	} `json:"author"`
	Source      side `json:"source"`
	Destination side `json:"destination"`
	Links       struct {
		HTML struct {
			Href string `json:"href"`
		} `json:"html"`
	} `json:"links"`
}

// side is the source or the destination of a PR in the JSON of Bitbucket.
type side struct {
	Branch struct {
		Name string `json:"name"`
	} `json:"branch"`
	Repository struct {
		FullName string `json:"full_name"`
	} `json:"repository"`
}

// SourceRepo reads the full name of the source repo from the JSON of one PR,
// for example the output of `pull-requests get`. A missing name is an error.
func SourceRepo(pr []byte) (string, error) {
	var p struct {
		Source side `json:"source"`
	}
	if err := decode(pr, &p); err != nil {
		return "", fmt.Errorf("PR: %w", err)
	}
	if p.Source.Repository.FullName == "" {
		return "", errors.New("the PR has no source repo")
	}
	return p.Source.Repository.FullName, nil
}

var hrefRepoRe = regexp.MustCompile(`bitbucket\.org/([^/]+/[^/]+)/`)

// decode reads JSON into v. An empty input leaves v empty.
func decode(b []byte, v any) error {
	if len(bytes.TrimSpace(b)) == 0 {
		return nil
	}
	return json.Unmarshal(b, v)
}

func (in inbox) prs(role Role, closed bool) []PR {
	var out []PR
	for _, it := range in.Items {
		r := role
		if closed {
			r = stateRole(it.State)
		}
		out = append(out, PR{
			Repo: it.Repo, ID: it.ID, Role: r, URL: it.Link,
			Src: it.SourceBranch, Dst: it.DestinationBranch,
			Author: it.Author.DisplayName, Title: it.Title, Draft: it.Draft,
			Sent: parseTime(it.CreatedOn), Updated: parseTime(it.UpdatedOn), UpdatedRaw: it.UpdatedOn,
		})
	}
	return out
}

// stateRole turns a state like MERGED into a role. A missing state is "closed".
func stateRole(state string) Role {
	if state == "" {
		return "closed"
	}
	return Role(strings.ToLower(state))
}

// queryPRs converts PRs of a repo query. The role of a PR is mine if me wrote
// it, and open if not. A closed list uses the state as the role.
func queryPRs(list []queryPR, me string, closed bool) []PR {
	var out []PR
	for _, q := range list {
		m := hrefRepoRe.FindStringSubmatch(q.Links.HTML.Href)
		if m == nil {
			continue
		}
		role := Open
		if me != "" && q.Author.UUID == me {
			role = Mine
		}
		if closed {
			role = stateRole(q.State)
		}
		out = append(out, PR{
			Repo: m[1], ID: q.ID, Role: role, URL: q.Links.HTML.Href,
			Src: q.Source.Branch.Name, Dst: q.Destination.Branch.Name, SrcRepo: q.Source.Repository.FullName,
			Author: q.Author.DisplayName, Title: q.Title, Draft: q.Draft,
			Sent: parseTime(q.CreatedOn), Updated: parseTime(q.UpdatedOn), UpdatedRaw: q.UpdatedOn,
		})
	}
	return out
}

// dedupe keeps the first PR for each key. It returns the PRs in the order of
// repo, then id. An inbox does not tell the source repo. Thus, if the kept PR
// has no SrcRepo, dedupe takes the SrcRepo of a later copy. Then a sync does
// not need to look up the source repo.
func dedupe(prs []PR) []PR {
	seen := map[string]int{}
	var out []PR
	for _, p := range prs {
		if i, ok := seen[p.Key()]; ok {
			if out[i].SrcRepo == "" {
				out[i].SrcRepo = p.SrcRepo
			}
			continue
		}
		seen[p.Key()] = len(out)
		out = append(out, p)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Repo != out[j].Repo {
			return out[i].Repo < out[j].Repo
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// MergeOpen joins the three sources of the open list. If two sources have the
// same PR, the first source wins: the author inbox, the reviewer inbox, then
// the repo query. An empty input is an empty source. The cur argument is the
// repo of the current directory. It does not change the result.
func MergeOpen(query, reviewer, author []byte, cur string) ([]PR, error) {
	var q []queryPR
	var r, a inbox
	if err := decode(query, &q); err != nil {
		return nil, fmt.Errorf("repo query: %w", err)
	}
	if err := decode(reviewer, &r); err != nil {
		return nil, fmt.Errorf("reviewer inbox: %w", err)
	}
	if err := decode(author, &a); err != nil {
		return nil, fmt.Errorf("author inbox: %w", err)
	}
	me := r.CurrentUser.UUID
	if me == "" {
		me = a.CurrentUser.UUID
	}
	all := append(a.prs(Mine, false), r.prs(Review, false)...)
	all = append(all, queryPRs(q, me, false)...)
	return dedupe(all), nil
}

// MergeClosed joins the lists of closed PRs. The role of each PR is its state.
func MergeClosed(merged, declined, author []byte) ([]PR, error) {
	var m, d []queryPR
	var a inbox
	if err := decode(merged, &m); err != nil {
		return nil, fmt.Errorf("merged PRs: %w", err)
	}
	if err := decode(declined, &d); err != nil {
		return nil, fmt.Errorf("declined PRs: %w", err)
	}
	if err := decode(author, &a); err != nil {
		return nil, fmt.Errorf("author inbox: %w", err)
	}
	all := a.prs("", true)
	all = append(all, queryPRs(m, "", true)...)
	all = append(all, queryPRs(d, "", true)...)
	return dedupe(all), nil
}

// Order is the sort order of the open list.
type Order string

const (
	Oldest Order = "oldest"
	Newest Order = "newest"
	ByRepo Order = "repo"
)

// Sort orders prs in place. For the list "closed", the newest change is
// first. For an open list, Oldest and Newest use the time sent. ByRepo puts
// the repo cur first, then sorts by repo name and by id, highest id first.
func Sort(prs []PR, list string, order Order, cur string) {
	less := func(i, j int) bool { return prs[i].Sent.Before(prs[j].Sent) }
	switch {
	case list == "closed":
		less = func(i, j int) bool { return prs[i].Updated.After(prs[j].Updated) }
	case order == Newest:
		less = func(i, j int) bool { return prs[i].Sent.After(prs[j].Sent) }
	case order == ByRepo:
		less = func(i, j int) bool {
			a, b := prs[i], prs[j]
			if (a.Repo == cur) != (b.Repo == cur) {
				return a.Repo == cur
			}
			if a.Repo != b.Repo {
				return a.Repo < b.Repo
			}
			return a.ID > b.ID
		}
	}
	sort.SliceStable(prs, less)
}

// Age formats a duration as 5m, 3h or 12d.
func Age(d time.Duration) string {
	switch {
	case d < time.Hour:
		return fmt.Sprintf("%dm", max(int(d/time.Minute), 0))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d/time.Hour))
	default:
		return fmt.Sprintf("%dd", int(d/(24*time.Hour)))
	}
}

// Filter returns the PRs that match q. The match ignores case. It looks at the
// title, the author, the repo, and the text "#<id>".
func Filter(prs []PR, q string) []PR {
	q = strings.ToLower(strings.TrimSpace(q))
	if q == "" {
		return prs
	}
	var out []PR
	for _, p := range prs {
		hay := strings.ToLower(fmt.Sprintf("%s\n%s\n%s\n#%d", p.Title, p.Author, p.Repo, p.ID))
		if strings.Contains(hay, q) {
			out = append(out, p)
		}
	}
	return out
}
