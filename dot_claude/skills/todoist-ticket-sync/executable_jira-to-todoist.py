#!/usr/bin/env python3
"""Copy the body of a Jira ticket into its Todoist task.

The transform is deterministic. The same ticket always makes the same text,
so a second run writes the same bytes and changes nothing.

The script reads the ticket through the `twg` CLI, Atlassian's own command
line tool, which already holds the credential. It needs no Jira token of its
own.

It converts the Atlassian Document Format body to Markdown, cuts the body at
the first horizontal rule, and adds a link to the ticket. Long tickets append
analysis and triage notes below that rule. The link carries them.

Usage:
    jira-to-todoist.py GTI-673            # print the text, write nothing
    jira-to-todoist.py GTI-673 --apply    # write it to the Todoist task
    jira-to-todoist.py --all --apply      # every task whose title holds a key

The Todoist token comes from TODOIST_API_TOKEN, or from `op read` against the
reference in TODOIST_OP_REF.

Exit codes: 0 success, 1 usage or credential error, 2 ticket not found,
3 no matching Todoist task.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

JIRA_BASE = "https://getrnd.atlassian.net/browse"
TODOIST_API = "https://api.todoist.com/rest/v2"
KEY_RE = re.compile(r"\b([A-Z][A-Z0-9]+-[0-9]+)\b")

# ---------------------------------------------------------------- ADF to text

MARK_WRAP = {
    "strong": ("**", "**"),
    "em": ("_", "_"),
    "code": ("`", "`"),
    "strike": ("~~", "~~"),
}


def inline(node):
    """Render one inline node."""
    kind = node.get("type")
    if kind == "text":
        out = node.get("text", "")
        href = None
        wraps = []
        for mark in node.get("marks", []):
            name = mark.get("type")
            if name == "link":
                href = mark.get("attrs", {}).get("href")
            elif name in MARK_WRAP:
                wraps.append(MARK_WRAP[name])
        # Apply in a fixed order so the output never varies.
        for open_s, close_s in wraps:
            out = f"{open_s}{out}{close_s}"
        if href:
            out = f"[{out}]({href})"
        return out
    if kind == "hardBreak":
        return "\n"
    if kind == "emoji":
        attrs = node.get("attrs", {})
        return attrs.get("text") or attrs.get("shortName", "")
    if kind == "mention":
        return "@" + node.get("attrs", {}).get("text", "").lstrip("@")
    if kind == "status":
        return node.get("attrs", {}).get("text", "")
    if kind == "date":
        return node.get("attrs", {}).get("timestamp", "")
    if kind in ("inlineCard", "blockCard"):
        return node.get("attrs", {}).get("url", "")
    return inlines(node.get("content", []))


def inlines(nodes):
    return "".join(inline(n) for n in nodes)


def cell_text(cell):
    """Flatten one table cell to a single line."""
    text = " ".join(
        inlines(child.get("content", [])) for child in cell.get("content", [])
    )
    return text.replace("|", "\\|").replace("\n", " ").strip()


def block(node, depth=0):
    """Render one block node to a list of lines. Returns None at a rule."""
    kind = node.get("type")

    if kind == "rule":
        return None

    if kind == "paragraph":
        return [inlines(node.get("content", []))]

    if kind == "heading":
        level = node.get("attrs", {}).get("level", 1)
        return ["#" * level + " " + inlines(node.get("content", []))]

    if kind in ("bulletList", "orderedList"):
        ordered = kind == "orderedList"
        pad = "  " * depth
        lines = []
        for i, item in enumerate(node.get("content", []), 1):
            marker = f"{i}. " if ordered else "- "
            inner = []
            for child in item.get("content", []):
                rendered = block(child, depth + 1)
                if rendered is None:
                    continue
                inner.extend(rendered)
            inner = [ln for ln in inner if ln.strip()]
            if not inner:
                continue
            lines.append(pad + marker + inner[0])
            for extra in inner[1:]:
                lines.append(pad + "  " + extra)
        return lines

    if kind == "taskList":
        lines = []
        for item in node.get("content", []):
            done = item.get("attrs", {}).get("state") == "DONE"
            box = "[x]" if done else "[ ]"
            lines.append(f"- {box} " + inlines(item.get("content", [])))
        return lines

    if kind == "codeBlock":
        lang = node.get("attrs", {}).get("language") or ""
        body = inlines(node.get("content", []))
        return ["```" + lang, *body.split("\n"), "```"]

    if kind in ("blockquote", "panel"):
        lines = []
        for child in node.get("content", []):
            rendered = block(child, depth)
            if rendered is None:
                continue
            lines.extend("> " + ln if ln else ">" for ln in rendered)
        return lines

    if kind == "table":
        rows = node.get("content", [])
        if not rows:
            return []
        lines = []
        for idx, row in enumerate(rows):
            cells = [cell_text(c) for c in row.get("content", [])]
            lines.append("| " + " | ".join(cells) + " |")
            if idx == 0:
                lines.append("| " + " | ".join("---" for _ in cells) + " |")
        return lines

    if kind in ("mediaSingle", "mediaGroup", "media"):
        return ["_(image in Jira)_"]

    if kind == "expand" or kind == "nestedExpand":
        title = node.get("attrs", {}).get("title", "")
        lines = [f"**{title}**"] if title else []
        for child in node.get("content", []):
            rendered = block(child, depth)
            if rendered is None:
                continue
            lines.extend(rendered)
        return lines

    # Unknown block: keep whatever text it holds rather than drop it.
    return [inlines(node.get("content", []))]


def adf_to_markdown(doc):
    """Convert an ADF document to Markdown. Stop at the first rule."""
    if not isinstance(doc, dict):
        return ""
    out = []
    for node in doc.get("content", []):
        rendered = block(node)
        if rendered is None:
            break
        rendered = [ln.rstrip() for ln in rendered]
        if not any(ln.strip() for ln in rendered):
            continue
        out.append("\n".join(rendered))
    text = "\n\n".join(out)
    # Collapse three or more blank lines so the output is stable.
    return re.sub(r"\n{3,}", "\n\n", text).strip()


# ------------------------------------------------------------------ Jira read


STDOUT_PATH_RE = re.compile(r'^\s*stdout:\s*"(.+)"\s*$', re.MULTILINE)


def fetch_issue(key):
    """Read one work item through the twg CLI.

    twg writes the payload to a temporary file and prints a YAML envelope that
    names it. The envelope also carries version notices, so parse the path out
    rather than reading the whole of stdout as JSON.
    """
    try:
        run = subprocess.run(
            [
                "twg", "jira", "workitem", "get", key,
                "--output", "json",
                "--select", "data.key,data.description",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except FileNotFoundError:
        sys.exit("error: the `twg` CLI is not installed")
    except subprocess.TimeoutExpired:
        sys.exit(f"error: `twg jira workitem get {key}` timed out")
    if run.returncode != 0:
        return None

    match = STDOUT_PATH_RE.search(run.stdout)
    if not match:
        return None
    try:
        with open(match.group(1), encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None

    items = payload.get("data")
    if not isinstance(items, list) or not items:
        return None
    return items[0]


def build_description(key):
    """Return the Todoist description for one ticket, or None if unknown."""
    issue = fetch_issue(key)
    if issue is None:
        return None
    # twg puts description at the top of the item; the REST shape nests it
    # under fields. Accept either.
    adf = issue.get("description")
    if adf is None:
        adf = (issue.get("fields") or {}).get("description")
    body = adf_to_markdown(adf)
    link = f"[{key}]({JIRA_BASE}/{key})"
    if not body:
        body = "The Jira ticket has no description."
    return f"{body}\n\n{link}"


# --------------------------------------------------------------- Todoist side


def todoist_token():
    token = os.environ.get("TODOIST_API_TOKEN")
    if token:
        return token.strip()
    ref = os.environ.get("TODOIST_OP_REF")
    if ref:
        got = subprocess.run(
            ["op", "read", ref], capture_output=True, text=True, timeout=30
        )
        if got.returncode == 0 and got.stdout.strip():
            return got.stdout.strip()
        sys.exit(f"error: `op read {ref}` returned nothing")
    sys.exit(
        "error: no Todoist token.\n"
        "Set TODOIST_API_TOKEN, or set TODOIST_OP_REF to a 1Password "
        "reference such as op://Private/Todoist/credential."
    )


def api(path, token, payload=None):
    url = f"{TODOIST_API}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    req.add_header("Authorization", f"Bearer {token}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode()
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as exc:
        sys.exit(f"error: Todoist returned {exc.code} for {path}: {exc.read()[:200]}")
    except urllib.error.URLError as exc:
        sys.exit(f"error: cannot reach Todoist: {exc.reason}")


def tasks_by_key(token):
    """Map each Jira key to the Todoist task whose title starts with it."""
    found = {}
    for task in api("/tasks", token):
        content = task.get("content", "")
        match = KEY_RE.match(content)
        if match:
            found[match.group(1)] = task
    return found


# ---------------------------------------------------------------------- Entry


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    apply_changes = "--apply" in flags
    do_all = "--all" in flags

    if not do_all and len(args) != 1:
        sys.exit(__doc__.strip())

    if not apply_changes and not do_all:
        text = build_description(args[0].upper())
        if text is None:
            sys.exit(f"error: cannot read {args[0]}")

        print(text)
        return 0

    token = todoist_token()
    index = tasks_by_key(token)

    keys = sorted(index) if do_all else [args[0].upper()]
    changed = unchanged = missing = 0

    for key in keys:
        task = index.get(key)
        if task is None:
            print(f"{key}: no Todoist task", file=sys.stderr)
            missing += 1
            continue
        text = build_description(key)
        if text is None:
            print(f"{key}: cannot read the Jira ticket", file=sys.stderr)
            missing += 1
            continue
        if task.get("description", "") == text:
            unchanged += 1
            continue
        if apply_changes:
            api(f"/tasks/{task['id']}", token, {"description": text})
            print(f"{key}: updated")
        else:
            print(f"{key}: would update")
        changed += 1

    print(
        f"\n{changed} changed, {unchanged} already correct, {missing} missing",
        file=sys.stderr,
    )
    return 0 if not missing else 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
