import { expect, test } from 'claude-code/testing'

import { gitCallFor, storedValueFor } from '../hooks/diff'
import { bitbucketPr, forgeOf, githubPr } from '../hooks/forge'
import { prTextOf } from '../hooks/pill'
import type { GitInfo } from '../types'

const PR = {
  id: 41,
  state: 'OPEN',
  draft: false,
  links: { html: { href: 'https://bitbucket.org/team/app/pull-requests/41' } },
  source: { commit: { hash: 'abc1234def56' } },
  participants: [{ approved: true, state: 'approved' }, { approved: false, state: null }],
  reviewers: [{}, {}],
  _tasks: [{ state: 'UNRESOLVED' }, { state: 'RESOLVED' }],
  _statuses: [{ state: 'SUCCESSFUL' }, { state: 'FAILED' }],
  comment_count: 3,
}

test('the forge comes from the remote, or from the Bitbucket directories', () => {
  const dirs = ['/home/me/work']
  const cases = [
    { remote: 'git@github.com:me/a.git', top: '/home/me/work/a', want: 'github' },
    { remote: 'https://bitbucket.org/team/a.git', top: '/x/a', want: 'bitbucket' },
    { remote: 'git@corp-alias:team/a.git', top: '/home/me/work/a', want: 'bitbucket' },
    { remote: 'git@corp-alias:team/a.git', top: '/home/me/workshop/a', want: null },
    { remote: '', top: '/x/a', want: null },
  ]
  for (const c of cases) expect(forgeOf(c.remote, c.top, dirs)).toBe(c.want)
})

test('a GitHub PR counts the latest review of each person, and its checks', () => {
  const pr = githubPr({
    number: 18,
    state: 'OPEN',
    isDraft: false,
    url: 'https://github.com/me/a/pull/18',
    headRefOid: 'f00',
    reviews: [
      { author: { login: 'ann' }, state: 'CHANGES_REQUESTED' },
      { author: { login: 'ann' }, state: 'APPROVED' },
      { author: { login: 'bob' }, state: 'CHANGES_REQUESTED' },
    ],
    reviewRequests: [{}],
    statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }, { status: 'IN_PROGRESS', conclusion: '' }],
    comments: [{}, {}],
  })
  expect(pr).toMatchObject({ state: 'open', approvals: 1, changesRequested: 1, reviewers: 3, build: 'running' })
  expect(githubPr({ number: 1, state: 'MERGED' })).toMatchObject({ state: 'merged' })
})

test('the diff panel reads the branch base until the person picks one', () => {
  expect(storedValueFor('base:/new', undefined)).toBe('branch')
  expect(storedValueFor('base:/picked', 'uncommitted')).toBe('uncommitted')
  expect(storedValueFor('other', undefined)).toBeUndefined()
})

test('a git call in the main checkout runs in the worktree of the session', () => {
  const linked = { isLinked: true, mainRoot: '/repo', top: '/w/x', gitDir: '/repo/.git/worktrees/x' } as GitInfo
  const panel = ['git', '--git-dir=/repo/.git', '--work-tree=/repo', 'diff']
  const cases = [
    {
      git: linked,
      call: { argv: panel, cwd: '/repo' },
      want: { argv: ['git', '--git-dir=/repo/.git/worktrees/x', '--work-tree=/w/x', 'diff'], cwd: '/w/x' },
    },
    { git: linked, call: { argv: ['git', 'status'], cwd: '/other' }, want: { argv: ['git', 'status'], cwd: '/other' } },
    { git: linked, call: { argv: ['ls'], cwd: '/repo' }, want: { argv: ['ls'], cwd: '/repo' } },
    { git: { ...linked, isLinked: false }, call: { argv: panel, cwd: '/repo' }, want: { argv: panel, cwd: '/repo' } },
  ]
  for (const c of cases) expect(gitCallFor(c.git, c.call)).toEqual(c.want)
})

test('the hint row ends with the state of the PR in words', () => {
  const open = {
    kind: 'pr', id: 19, state: 'open', url: '', headSha: '', sync: null,
    approvals: 1, changesRequested: 0, reviewers: 2, openTasks: 0, comments: 3, build: 'running',
  } as const
  expect(prTextOf(open)).toBe('open · 1/2 approved · CI running · 3 comments')
  expect(prTextOf({ ...open, state: 'merged' })).toBe('merged')
  expect(prTextOf({ kind: 'none' })).toBe('')

  // Bitbucket: Claude Code shows no PR link, so the text carries the number.
  expect(prTextOf(open, true)).toBe('PR#19 open · 1/2 approved · CI running · 3 comments')

  // /pr-copy copies pr.url, so a Bitbucket PR must carry its web URL too.
  expect(bitbucketPr(PR)).toMatchObject({ id: 41, url: 'https://bitbucket.org/team/app/pull-requests/41' })
})
