import type { GitInfo, Palette, PrInfo } from '../types'

// The pill the status line prints at its right edge, as ANSI text with
// 256-color codes (tmux here reports RGB=no). Its colors come from
// ~/.claude/palette.json, the file the status line reads too. Color is for
// state only: the words share the surface color, and a word takes a state
// color when it needs attention.

// The rounded caps: Nerd Font glyphs. Ghostty draws them without a patched font.
const ICON = {
  capLeft: '',
  capRight: '',
} as const

// The palette when palette.json cannot be read: the same values as the file.
export const DEFAULT_PALETTE: Palette = {
  surface: 236,
  surface_dim: 234,
  text: 252,
  dim: 248,
  ok: 108,
  warn: 215,
  crit: 204,
  merged: 141,
}

// palette.json holds { name: { hex, ansi } }; this keeps the 256-color numbers.
export function paletteOf(json: string): Palette {
  const file = JSON.parse(json) as Record<string, { ansi?: number }>
  const palette = { ...DEFAULT_PALETTE }
  for (const key of Object.keys(palette) as (keyof Palette)[]) {
    const ansi = file[key]?.ansi
    if (typeof ansi === 'number') palette[key] = ansi
  }
  return palette
}

type Segment = { bg: number; fg: number; text: string }

const fg = (n: number) => `\x1b[38;5;${n}m`
const bg = (n: number) => `\x1b[48;5;${n}m`
const RESET = '\x1b[0m'

export const DEFAULT_BRANCHES = new Set(['main', 'master', 'develop', 'HEAD'])

// The state of the PR as plain words, for the end of the hint row under the
// prompt. For a GitHub PR that row already shows "PR #<n>" as a link, so the
// number is not repeated; for Bitbucket (`withNumber`) the text starts with
// "PR#<n>". Claude Code draws the text dim and without color, puts " · "
// before it, and collapses spaces, so it carries no ANSI codes or padding.
export function prTextOf(pr: PrInfo | null, withNumber = false): string {
  if (pr?.kind !== 'pr') return ''
  const parts: string[] = [withNumber ? `PR#${pr.id} ${pr.state}` : pr.state]
  if (pr.state === 'open' || pr.state === 'draft') {
    if (pr.reviewers || pr.approvals) parts.push(`${pr.approvals}/${Math.max(pr.reviewers, pr.approvals)} approved`)
    if (pr.changesRequested) parts.push(`${pr.changesRequested} changes requested`)
    if (pr.build) parts.push(`CI ${pr.build === 'ok' ? 'passed' : pr.build === 'fail' ? 'failed' : 'running'}`)
    if (pr.comments) parts.push(`${pr.comments} comment${pr.comments === 1 ? '' : 's'}`)
    if (pr.openTasks) parts.push(`${pr.openTasks} task${pr.openTasks === 1 ? '' : 's'}`)
  }
  return parts.join(' · ')
}

// The pill of row 1 of the status line: the worktree and the local changes.
// The PR is on row 2 (see prTextOf).
export function pillOf(git: GitInfo, c: Palette = DEFAULT_PALETTE): string {
  // Text in a state color, then back to the text color of the segment.
  const hue = (color: number, text: string, back = c.text) => `${fg(color)}${text}${fg(back)}`
  const segments: Segment[] = []
  const isMainCheckout = !git.isLinked && DEFAULT_BRANCHES.has(git.branch)

  // Each part is words, so the pill reads without a legend. The branch is not
  // here: the tmux status line already shows it.

  // Where: repository/worktree, or the repository and "main checkout".
  const repo = nameOf(git.mainRoot.split('/').pop() ?? git.mainRoot)
  const worktree = nameOf(git.worktree)
  const where = git.isLinked
    ? `${repo}/${worktree}`
    : `${worktree} ${hue(isMainCheckout && git.changed ? c.warn : c.dim, 'main checkout')}`
  const drift = [
    git.ahead ? `${git.ahead} unpushed` : '',
    git.behind ? hue(c.warn, `${git.behind} behind`) : '',
  ].filter(Boolean)
  segments.push({ bg: c.surface, fg: c.text, text: [where, ...drift].join(' ') })

  // The local changes: green when all of them are staged, warn while some are not.
  const changes = [
    git.changed ? hue(git.staged === git.changed ? c.ok : c.warn, `${git.staged}/${git.changed} staged`) : '',
    git.hasCommitMsg ? hue(c.ok, 'msg ready') : '',
    git.hasPrMsg ? hue(c.ok, 'PR draft ready') : '',
  ].filter(Boolean)
  if (changes.length) segments.push({ bg: c.surface, fg: c.text, text: changes.join(' ') })

  return render(segments, c)
}

// The pill when the directory of the session is not in a git repository: the
// name of the directory, so the status line still shows the pill.
export function dirPillOf(dir: string, c: Palette = DEFAULT_PALETTE): string {
  return render([{ bg: c.surface, fg: c.text, text: `${nameOf(dir)} ${fg(c.dim)}no git${fg(c.text)}` }], c)
}

// The name of a directory can hold any byte except "/". The status line prints
// the pill as it is, so a name with an escape character could send control
// codes to the terminal. Remove the control characters (C0, DEL and C1).
export function nameOf(name: string): string {
  return name.replace(/[\x00-\x1f\x7f-\x9f]/g, '')
}

function render(segments: Segment[], c: Palette): string {
  const first = segments[0]!
  const last = segments[segments.length - 1]!
  // A dim dot between the parts.
  const body = segments.map((s, i) => `${bg(s.bg)}${fg(s.fg)}${i ? `${fg(c.dim)} · ${fg(s.fg)}` : ''}${s.text}`).join('')
  return `${fg(first.bg)}${ICON.capLeft}${body}${RESET}${fg(last.bg)}${ICON.capRight}${RESET}`
}
