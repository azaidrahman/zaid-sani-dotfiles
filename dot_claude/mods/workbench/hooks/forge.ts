import type { Build, Forge, PrInfo, PrState } from '../types'

// What the PR of a branch looks like on each forge, as the same PrInfo.

// The remote names the forge. When it does not (an SSH host alias, say), a
// repository under one of `bitbucketDirs` is on Bitbucket. The person lists
// those directories in a local file, so that no company path is in the mod.
export function forgeOf(remote: string, top: string, bitbucketDirs: readonly string[]): Forge | null {
  if (remote.includes('github.com')) return 'github'
  if (remote.includes('bitbucket.org')) return 'bitbucket'
  const isUnder = (dir: string) => top === dir || top.startsWith(`${dir.replace(/\/+$/, '')}/`)
  return bitbucketDirs.some(isUnder) ? 'bitbucket' : null
}

// The file holds one directory on each line; `~` is the home directory, and a
// line that starts with `#` is a comment.
export function dirsOf(text: string, home: string): string[] {
  return text
    .split('\n')
    .map(line => line.trim())
    .filter(line => line && !line.startsWith('#'))
    .map(line => line.replace(/^~(?=\/|$)/, home))
}

// `gh pr view <branch> --json` with GITHUB_FIELDS.
export const GITHUB_FIELDS = 'number,state,isDraft,url,headRefOid,reviews,reviewRequests,statusCheckRollup,comments'

export function githubPr(json: any): PrInfo {
  const state: PrState =
    json.state === 'MERGED' ? 'merged' : json.state === 'CLOSED' ? 'closed' : json.isDraft ? 'draft' : 'open'
  // The latest review of each person counts.
  const latest = new Map<string, string>()
  for (const review of json.reviews ?? []) latest.set(review.author?.login ?? '', review.state)
  const verdicts = [...latest.values()]
  const approvals = verdicts.filter(v => v === 'APPROVED').length
  const changesRequested = verdicts.filter(v => v === 'CHANGES_REQUESTED').length
  return {
    kind: 'pr',
    id: json.number,
    state,
    url: json.url ?? '',
    headSha: json.headRefOid ?? '',
    sync: null,
    approvals,
    changesRequested,
    reviewers: (json.reviewRequests ?? []).length + approvals + changesRequested,
    openTasks: 0,
    comments: (json.comments ?? []).length,
    build: githubBuild(json.statusCheckRollup),
  }
}

// A check run has a status and a conclusion; a commit status has a state.
function githubBuild(checks: Array<{ status?: string; conclusion?: string; state?: string }> | undefined): Build {
  if (!checks?.length) return null
  const results = checks.map(c => c.conclusion || c.state || '')
  if (results.some(r => ['FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED'].includes(r))) return 'fail'
  if (checks.some(c => (c.status && c.status !== 'COMPLETED') || c.state === 'PENDING')) return 'running'
  return 'ok'
}

// `twg bb prs get <id>`: a Bitbucket Cloud PR, with its tasks and statuses.
export function bitbucketPr(json: any): PrInfo {
  const participants: any[] = json.participants ?? []
  const state: PrState =
    json.state === 'MERGED' ? 'merged' : json.state === 'OPEN' ? (json.draft ? 'draft' : 'open') : 'closed'
  return {
    kind: 'pr',
    id: json.id,
    state,
    url: json.links?.html?.href ?? '',
    headSha: json.source?.commit?.hash ?? '',
    sync: null,
    approvals: participants.filter(p => p.approved).length,
    changesRequested: participants.filter(p => p.state === 'changes_requested').length,
    reviewers: (json.reviewers ?? []).length,
    openTasks: (json._tasks ?? []).filter((t: any) => t.state === 'UNRESOLVED').length,
    comments: json.comment_count ?? 0,
    build: bitbucketBuild(json._statuses),
  }
}

function bitbucketBuild(statuses: Array<{ state?: string }> | undefined): Build {
  if (!statuses?.length) return null
  if (statuses.some(s => s.state === 'FAILED' || s.state === 'STOPPED')) return 'fail'
  if (statuses.some(s => s.state === 'INPROGRESS')) return 'running'
  return 'ok'
}
