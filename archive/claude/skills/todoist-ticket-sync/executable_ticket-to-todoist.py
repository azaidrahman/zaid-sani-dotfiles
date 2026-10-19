#!/usr/bin/env python3
"""Copy the body of a tracker ticket into its Todoist task.

The transform is deterministic. The same ticket always makes the same text,
so a second run writes the same bytes and changes nothing.

The tracker sits behind a provider. Jira is the only provider today. To add
another, such as Linear, write one class and add one registry entry. Read
"Adding a provider" below. Nothing outside a provider class knows which
tracker is in use.

Usage:
    ticket-to-todoist.py GTI-673            # print the text, write nothing
    ticket-to-todoist.py GTI-673 --apply    # write it to the Todoist task
    ticket-to-todoist.py --all              # report what would change
    ticket-to-todoist.py --all --apply      # refresh every matching task
    ticket-to-todoist.py --providers        # list providers and their state

Pick the provider with TICKET_PROVIDER. The default is `jira`.

The Todoist token comes from TODOIST_API_TOKEN, or from `op read` against the
reference in TODOIST_OP_REF.

Exit codes: 0 success, 1 usage or credential error, 3 a ticket or a task was
missing.

Adding a provider
-----------------
Subclass TicketProvider and set:

    name       the value that TICKET_PROVIDER takes
    key_re     a full-match pattern for a ticket key

Then write three methods:

    available()      is the credential or the CLI present on this device
    fetch(key)       return the raw ticket, or None when it does not exist
    body(raw)        return Markdown, already cut at the first horizontal rule
    url(key)         return the address a person can open

Add the class to PROVIDERS. Nothing else changes. The Todoist half, the
matching of task titles, the no-op check, and the command line stay as they
are.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

# The v1 API. The older rest/v2 endpoints now answer 410.
TODOIST_API = "https://api.todoist.com/api/v1"


# ===========================================================================
# Provider contract
# ===========================================================================


class TicketProvider:
    """One issue tracker."""

    name = ""
    key_re = re.compile(r"(?!)")  # never matches; a subclass must set this

    def available(self):
        """Is this provider usable on this device?  Returns (ok, reason)."""
        raise NotImplementedError

    def fetch(self, key):
        """Return the raw ticket, or None when it cannot be read."""
        raise NotImplementedError

    def body(self, raw):
        """Return the ticket body as Markdown, cut at the first rule."""
        raise NotImplementedError

    def url(self, key):
        """Return the address a person can open."""
        raise NotImplementedError

    # -- shared, and the same for every provider ---------------------------

    def description(self, key):
        """Return the full Todoist description for one ticket."""
        raw = self.fetch(key)
        if raw is None:
            return None
        text = self.body(raw).strip()
        if not text:
            text = "The ticket has no description."
        return f"{text}\n\n[{key}]({self.url(key)})"


# ===========================================================================
# Jira
# ===========================================================================

# Atlassian Document Format lives here, with the Jira provider, because no
# other tracker uses it.

_ADF_MARKS = {
    "strong": ("**", "**"),
    "em": ("_", "_"),
    "code": ("`", "`"),
    "strike": ("~~", "~~"),
}


def _adf_inline(node):
    kind = node.get("type")
    if kind == "text":
        out = node.get("text", "")
        href = None
        wraps = []
        for mark in node.get("marks", []):
            name = mark.get("type")
            if name == "link":
                href = mark.get("attrs", {}).get("href")
            elif name in _ADF_MARKS:
                wraps.append(_ADF_MARKS[name])
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
    return _adf_inlines(node.get("content", []))


def _adf_inlines(nodes):
    return "".join(_adf_inline(n) for n in nodes)


def _adf_cell(cell):
    text = " ".join(
        _adf_inlines(child.get("content", [])) for child in cell.get("content", [])
    )
    return text.replace("|", "\\|").replace("\n", " ").strip()


def _adf_block(node, depth=0):
    """Render one block node to lines. Returns None at a horizontal rule."""
    kind = node.get("type")

    if kind == "rule":
        return None

    if kind == "paragraph":
        return [_adf_inlines(node.get("content", []))]

    if kind == "heading":
        level = node.get("attrs", {}).get("level", 1)
        return ["#" * level + " " + _adf_inlines(node.get("content", []))]

    if kind in ("bulletList", "orderedList"):
        ordered = kind == "orderedList"
        pad = "  " * depth
        lines = []
        for i, item in enumerate(node.get("content", []), 1):
            marker = f"{i}. " if ordered else "- "
            inner = []
            for child in item.get("content", []):
                rendered = _adf_block(child, depth + 1)
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
            lines.append(f"- {box} " + _adf_inlines(item.get("content", [])))
        return lines

    if kind == "codeBlock":
        lang = node.get("attrs", {}).get("language") or ""
        return ["```" + lang, *_adf_inlines(node.get("content", [])).split("\n"), "```"]

    if kind in ("blockquote", "panel"):
        lines = []
        for child in node.get("content", []):
            rendered = _adf_block(child, depth)
            if rendered is None:
                continue
            lines.extend("> " + ln if ln else ">" for ln in rendered)
        return lines

    if kind == "table":
        rows = node.get("content", [])
        lines = []
        for idx, row in enumerate(rows):
            cells = [_adf_cell(c) for c in row.get("content", [])]
            lines.append("| " + " | ".join(cells) + " |")
            if idx == 0:
                lines.append("| " + " | ".join("---" for _ in cells) + " |")
        return lines

    if kind in ("mediaSingle", "mediaGroup", "media"):
        return ["_(image in the ticket)_"]

    if kind in ("expand", "nestedExpand"):
        title = node.get("attrs", {}).get("title", "")
        lines = [f"**{title}**"] if title else []
        for child in node.get("content", []):
            rendered = _adf_block(child, depth)
            if rendered is None:
                continue
            lines.extend(rendered)
        return lines

    return [_adf_inlines(node.get("content", []))]


def adf_to_markdown(doc):
    """Convert an ADF document to Markdown, stopping at the first rule."""
    if not isinstance(doc, dict):
        return ""
    out = []
    for node in doc.get("content", []):
        rendered = _adf_block(node)
        if rendered is None:
            break
        rendered = [ln.rstrip() for ln in rendered]
        if not any(ln.strip() for ln in rendered):
            continue
        out.append("\n".join(rendered))
    return re.sub(r"\n{3,}", "\n\n", "\n\n".join(out)).strip()


class JiraProvider(TicketProvider):
    """Jira, read through Atlassian's own twg CLI.

    twg already holds the credential, so this provider needs no token. twg
    writes the payload to a temporary file and prints a YAML envelope naming
    it. The envelope also carries version notices, so the path is parsed out
    rather than reading stdout as JSON.
    """

    name = "jira"
    key_re = re.compile(r"[A-Z][A-Z0-9]+-[0-9]+")
    site = os.environ.get("JIRA_SITE", "https://getrnd.atlassian.net")

    _stdout_re = re.compile(r'^\s*stdout:\s*"(.+)"\s*$', re.MULTILINE)

    def available(self):
        try:
            subprocess.run(["twg", "--version"], capture_output=True, timeout=20)
        except FileNotFoundError:
            return False, "the twg CLI is not installed"
        except subprocess.TimeoutExpired:
            return False, "twg did not respond"
        return True, ""

    def fetch(self, key):
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
            sys.exit("error: the twg CLI is not installed")
        except subprocess.TimeoutExpired:
            return None
        if run.returncode != 0:
            return None
        match = self._stdout_re.search(run.stdout)
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

    def body(self, raw):
        adf = raw.get("description")
        if adf is None:
            adf = (raw.get("fields") or {}).get("description")
        return adf_to_markdown(adf)

    def url(self, key):
        return f"{self.site.rstrip('/')}/browse/{key}"


# ===========================================================================
# Registry
# ===========================================================================

PROVIDERS = {
    JiraProvider.name: JiraProvider,
}

DEFAULT_PROVIDER = "jira"


def get_provider():
    chosen = os.environ.get("TICKET_PROVIDER", DEFAULT_PROVIDER).strip().lower()
    if chosen not in PROVIDERS:
        known = ", ".join(sorted(PROVIDERS))
        sys.exit(f"error: unknown TICKET_PROVIDER {chosen!r}. Known: {known}")
    return PROVIDERS[chosen]()


# ===========================================================================
# Todoist, which knows nothing about any tracker
# ===========================================================================


# The keychain entry that holds the 1Password service account token. This is
# the same entry that git-credential-op uses. The account is scoped to the
# Personal Development vault, which is where the Todoist item sits.
SA_KEYCHAIN_ENTRY = os.environ.get(
    "TODOIST_OP_SA_ENTRY", "op-service-account-token-personal"
)


def service_account_env():
    """Return an environment that lets `op` run without the desktop app.

    Without a service account token, `op read` falls through to the 1Password
    desktop app. That path needs the app running and unlocked, it can raise a
    Touch ID prompt, and it takes about four seconds. A service account token
    makes the same read headless and fast.

    Returns the current environment unchanged when no token is available, so
    the desktop app stays as the fallback.
    """
    env = os.environ.copy()
    if env.get("OP_SERVICE_ACCOUNT_TOKEN"):
        return env
    try:
        got = subprocess.run(
            [
                "security", "find-generic-password",
                "-a", os.environ.get("USER", ""),
                "-s", SA_KEYCHAIN_ENTRY,
                "-w",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return env
    if got.returncode == 0 and got.stdout.strip():
        env["OP_SERVICE_ACCOUNT_TOKEN"] = got.stdout.strip()
    return env


def todoist_token():
    token = os.environ.get("TODOIST_API_TOKEN")
    if token:
        return token.strip()
    ref = os.environ.get("TODOIST_OP_REF")
    if ref:
        env = service_account_env()
        try:
            got = subprocess.run(
                ["op", "read", ref],
                capture_output=True,
                text=True,
                timeout=20,
                env=env,
            )
        except FileNotFoundError:
            sys.exit("error: the `op` CLI is not installed")
        except subprocess.TimeoutExpired:
            # With no service account token, `op` asks the desktop app, which
            # waits for a person to unlock it. Nobody answers that in a hook.
            if "OP_SERVICE_ACCOUNT_TOKEN" in env:
                sys.exit(f"error: `op read {ref}` timed out")
            sys.exit(
                f"error: `op read {ref}` timed out after 20s.\n"
                f"No service account token was found in the keychain entry "
                f"{SA_KEYCHAIN_ENTRY}, so `op` fell back to the desktop app "
                "and waited for it to be unlocked.\n"
                "Add the entry, or unlock 1Password, or set "
                "TODOIST_API_TOKEN directly."
            )
        if got.returncode == 0 and got.stdout.strip():
            return got.stdout.strip()
        detail = got.stderr.strip().splitlines()[-1] if got.stderr.strip() else ""
        sys.exit(
            f"error: `op read {ref}` returned nothing. {detail}\n"
            f"Check the keychain entry {SA_KEYCHAIN_ENTRY}, or run "
            "`,op-sa-health`."
        )
    sys.exit(
        "error: no Todoist token.\n"
        "Set TODOIST_API_TOKEN, or set TODOIST_OP_REF to a 1Password "
        "reference such as op://Private/Todoist/credential."
    )


def api(path, token, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{TODOIST_API}{path}", data=data, method="POST" if data else "GET"
    )
    req.add_header("Authorization", f"Bearer {token}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            text = resp.read().decode()
            return json.loads(text) if text.strip() else {}
    except urllib.error.HTTPError as exc:
        sys.exit(f"error: Todoist returned {exc.code} for {path}: {exc.read()[:200]}")
    except urllib.error.URLError as exc:
        sys.exit(f"error: cannot reach Todoist: {exc.reason}")


def all_tasks(token):
    """Every active task. The v1 list endpoints page through a cursor."""
    out = []
    cursor = None
    while True:
        path = "/tasks?limit=200" + (f"&cursor={cursor}" if cursor else "")
        page = api(path, token)
        if isinstance(page, list):  # defensive: an older shape
            out.extend(page)
            break
        out.extend(page.get("results", []))
        cursor = page.get("next_cursor")
        if not cursor:
            break
    return out


def tasks_by_key(token, provider):
    """Map each key to the Todoist task whose title starts with that key."""
    found = {}
    for task in all_tasks(token):
        match = provider.key_re.match(task.get("content", ""))
        if match:
            found[match.group(0)] = task
    return found


# ===========================================================================
# Entry
# ===========================================================================


def main(argv):
    flags = {a for a in argv if a.startswith("--")}
    args = [a for a in argv if not a.startswith("--")]
    apply_changes = "--apply" in flags
    do_all = "--all" in flags

    if "--providers" in flags:
        for name, cls in sorted(PROVIDERS.items()):
            ok, why = cls().available()
            mark = "ready" if ok else f"unavailable ({why})"
            default = "  [default]" if name == DEFAULT_PROVIDER else ""
            print(f"{name}: {mark}{default}")
        return 0

    if not do_all and len(args) != 1:
        sys.exit(__doc__.strip())

    provider = get_provider()
    ok, why = provider.available()
    if not ok:
        sys.exit(f"error: provider {provider.name} is unavailable: {why}")

    # One ticket, printed. No token needed.
    if not do_all and not apply_changes:
        key = args[0].upper()
        if not provider.key_re.fullmatch(key):
            sys.exit(f"error: {key} is not a {provider.name} key")
        text = provider.description(key)
        if text is None:
            sys.exit(f"error: cannot read {key}")
        print(text)
        return 0

    token = todoist_token()
    index = tasks_by_key(token, provider)
    keys = sorted(index) if do_all else [args[0].upper()]

    changed = unchanged = missing = 0
    for key in keys:
        task = index.get(key)
        if task is None:
            print(f"{key}: no Todoist task", file=sys.stderr)
            missing += 1
            continue
        text = provider.description(key)
        if text is None:
            print(f"{key}: cannot read the ticket", file=sys.stderr)
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
    return 3 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
