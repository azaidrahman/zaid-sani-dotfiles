import type { PrInfo } from '../types'

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
