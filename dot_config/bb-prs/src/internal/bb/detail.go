package bb

import (
	"fmt"
	"sort"
	"strings"
)

// Details is the data of the details view of one PR.
type Details struct {
	ID          int
	Title       string
	Author      string
	Src, Dst    string
	State       string
	Updated     string // "2006-01-02 15:04"
	Description string
	Comments    int
	Tasks       int
	ApprovedBy  []string
	Reviewers   []string
	ClosedBy    string
	Draft       bool
	// Merge is the reason or the status of the git merge check.
	Merge string
	// GitStatus is the status of the git merge check in upper case, for
	// example PASSED or FAILED. It is empty if there is no git check.
	GitStatus string
	// Failing lists each failed check that is not the git merge check.
	Failing []string
	Files   []File
}

// File is one changed file of a PR.
type File struct {
	Status  string // one letter, for example "M"
	Added   int
	Removed int
	Path    string
}

type user struct {
	DisplayName string `json:"display_name"`
}

// shortTime turns "2006-01-02T15:04:05..." into "2006-01-02 15:04".
func shortTime(s string) string {
	if len(s) > 16 {
		s = s[:16]
	}
	return strings.Replace(s, "T", " ", 1)
}

// firstLine returns the first line of s.
func firstLine(s string) string {
	line, _, _ := strings.Cut(s, "\n")
	return line
}

// truncate cuts s to n characters.
func truncate(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}

// ParseDetails reads the JSON of `pull-requests get`, `mergeability`, and
// `diffstat`. Only a bad pr payload is an error. A checks or diffstat payload
// that is empty or bad gives no checks or no files.
func ParseDetails(pr, checks, diffstat []byte) (Details, error) {
	var p struct {
		ID           int    `json:"id"`
		Title        string `json:"title"`
		State        string `json:"state"`
		Draft        bool   `json:"draft"`
		UpdatedOn    string `json:"updated_on"`
		CommentCount int    `json:"comment_count"`
		TaskCount    int    `json:"task_count"`
		Description  string `json:"description"`
		Author       user   `json:"author"`
		ClosedBy     *user  `json:"closed_by"`
		Source       struct {
			Branch struct {
				Name string `json:"name"`
			} `json:"branch"`
		} `json:"source"`
		Destination struct {
			Branch struct {
				Name string `json:"name"`
			} `json:"branch"`
		} `json:"destination"`
		Participants []struct {
			Approved bool `json:"approved"`
			User     user `json:"user"`
		} `json:"participants"`
		Reviewers []user `json:"reviewers"`
	}
	if err := decode(pr, &p); err != nil {
		return Details{}, fmt.Errorf("PR: %w", err)
	}
	d := Details{
		ID: p.ID, Title: p.Title, Author: p.Author.DisplayName,
		Src: p.Source.Branch.Name, Dst: p.Destination.Branch.Name,
		State: p.State, Updated: shortTime(p.UpdatedOn), Description: p.Description,
		Comments: p.CommentCount, Tasks: p.TaskCount, Draft: p.Draft, Merge: "unknown",
	}
	if p.ClosedBy != nil {
		d.ClosedBy = p.ClosedBy.DisplayName
	}
	for _, x := range p.Participants {
		if x.Approved {
			d.ApprovedBy = append(d.ApprovedBy, x.User.DisplayName)
		}
	}
	for _, r := range p.Reviewers {
		d.Reviewers = append(d.Reviewers, r.DisplayName)
	}

	var cs []struct {
		Type   string `json:"type"`
		Status string `json:"status"`
		Reason string `json:"reason"`
		Check  struct {
			Kind string `json:"kind"`
		} `json:"check"`
		Requirement struct {
			MinimumApprovals *int `json:"minimum_approvals"`
		} `json:"requirement"`
		Observed struct {
			ApprovalCount int `json:"approval_count"`
		} `json:"observed"`
	}
	// A bad checks payload is not an error: the merge state stays "unknown".
	if err := decode(checks, &cs); err != nil {
		cs = nil
	}
	const gitCheck = "git_mergeability_check"
	gitSeen := false
	for _, c := range cs {
		if c.Type == gitCheck {
			if !gitSeen {
				gitSeen = true
				d.GitStatus = strings.ToUpper(c.Status)
				d.Merge = c.Reason
				if d.Merge == "" {
					d.Merge = c.Status
				}
				if d.Merge == "" {
					d.Merge = "unknown"
				}
			}
			continue
		}
		if c.Status != "FAILED" {
			continue
		}
		name := c.Check.Kind
		if name == "" {
			name = c.Type
		}
		if c.Requirement.MinimumApprovals != nil {
			name += fmt.Sprintf(" %d/%d", c.Observed.ApprovalCount, *c.Requirement.MinimumApprovals)
		}
		d.Failing = append(d.Failing, name)
	}

	var fs []struct {
		Status       string `json:"status"`
		LinesAdded   int    `json:"lines_added"`
		LinesRemoved int    `json:"lines_removed"`
		New          *struct {
			Path string `json:"path"`
		} `json:"new"`
		Old *struct {
			Path string `json:"path"`
		} `json:"old"`
	}
	// A bad diffstat payload is not an error: the list of files stays empty.
	if err := decode(diffstat, &fs); err != nil {
		fs = nil
	}
	for _, f := range fs {
		path := ""
		switch {
		case f.New != nil && f.New.Path != "":
			path = f.New.Path
		case f.Old != nil:
			path = f.Old.Path
		}
		d.Files = append(d.Files, File{
			Status: strings.ToUpper(truncate(f.Status, 1)),
			Added:  f.LinesAdded, Removed: f.LinesRemoved, Path: path,
		})
	}
	return d, nil
}

// Event is one line of the activity of a PR.
type Event struct {
	Time string // "2006-01-02 15:04"
	Who  string
	What string
}

// ParseActivity reads the JSON of `pull-requests activity`. The result is
// oldest first. The oldest event is "opened" if it is an update.
func ParseActivity(b []byte) ([]Event, error) {
	var raw []map[string]struct {
		Date      string `json:"date"`
		CreatedOn string `json:"created_on"`
		UpdatedOn string `json:"updated_on"`
		State     string `json:"state"`
		Author    *user  `json:"author"`
		User      *user  `json:"user"`
		Content   struct {
			Raw string `json:"raw"`
		} `json:"content"`
		Inline *struct {
			Path string `json:"path"`
			To   *int   `json:"to"`
			From *int   `json:"from"`
		} `json:"inline"`
		Changes map[string]any `json:"changes"`
	}
	if err := decode(b, &raw); err != nil {
		return nil, fmt.Errorf("activity: %w", err)
	}
	type item struct {
		sortKey string
		Event
	}
	var items []item
	for _, entry := range raw {
		delete(entry, "pull_request")
		// An event has one key. If it has more, take the first by name.
		kinds := make([]string, 0, len(entry))
		for k := range entry {
			kinds = append(kinds, k)
		}
		if len(kinds) == 0 {
			continue
		}
		sort.Strings(kinds)
		kind, v := kinds[0], entry[kinds[0]]

		t := firstNonEmpty(v.Date, v.CreatedOn, v.UpdatedOn)
		who := "?"
		switch {
		case v.Author != nil && v.Author.DisplayName != "":
			who = v.Author.DisplayName
		case v.User != nil && v.User.DisplayName != "":
			who = v.User.DisplayName
		}
		var what string
		switch kind {
		case "approval":
			what = "approved"
		case "changes_requested":
			what = "requested changes"
		case "comment":
			what = "commented"
			if v.Inline != nil && v.Inline.Path != "" {
				what += " on " + v.Inline.Path + ":"
				switch {
				case v.Inline.To != nil:
					what += fmt.Sprint(*v.Inline.To)
				case v.Inline.From != nil:
					what += fmt.Sprint(*v.Inline.From)
				}
			}
			what += ": " + truncate(firstLine(v.Content.Raw), 100)
		case "update":
			_, hasStatus := v.Changes["status"]
			switch {
			case hasStatus:
				what = strings.ToLower(v.State)
			case len(v.Changes) > 0:
				keys := make([]string, 0, len(v.Changes))
				for k := range v.Changes {
					keys = append(keys, k)
				}
				sort.Strings(keys)
				what = "changed " + strings.Join(keys, ", ")
			default:
				what = "updated"
			}
		default:
			what = kind
		}
		items = append(items, item{t, Event{Time: shortTime(t), Who: who, What: strings.ReplaceAll(what, "\t", " ")}})
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].sortKey < items[j].sortKey })
	events := make([]Event, len(items))
	for i, it := range items {
		events[i] = it.Event
	}
	if len(events) > 0 && events[0].What == "updated" {
		events[0].What = "opened"
	}
	return events, nil
}

func firstNonEmpty(s ...string) string {
	for _, x := range s {
		if x != "" {
			return x
		}
	}
	return ""
}

// Commit is one commit of a PR.
type Commit struct {
	Hash    string // 8 characters
	Full    string // the full hash
	Date    string // "2006-01-02 15:04"
	Who     string
	Message string // the whole message, without the space at the start and the end
}

// Subject returns the first line of the message.
func (c Commit) Subject() string { return firstLine(c.Message) }

// ParseCommits reads the JSON of `pull-requests commits`. The result is
// newest first, as twg gives it.
func ParseCommits(b []byte) ([]Commit, error) {
	var raw []struct {
		Hash    string `json:"hash"`
		Date    string `json:"date"`
		Message string `json:"message"`
		Author  struct {
			Raw  string `json:"raw"`
			User *user  `json:"user"`
		} `json:"author"`
	}
	if err := decode(b, &raw); err != nil {
		return nil, fmt.Errorf("commits: %w", err)
	}
	out := make([]Commit, 0, len(raw))
	for _, c := range raw {
		who := "?"
		switch {
		case c.Author.User != nil && c.Author.User.DisplayName != "":
			who = c.Author.User.DisplayName
		case c.Author.Raw != "":
			who, _, _ = strings.Cut(c.Author.Raw, " <")
		}
		out = append(out, Commit{
			Hash: truncate(c.Hash, 8), Full: c.Hash, Date: shortTime(c.Date), Who: who,
			Message: strings.TrimSpace(c.Message),
		})
	}
	return out, nil
}
