import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { gitCallFor, storedValueFor } from '../hooks/diff'
import { bitbucketPr, forgeOf, githubPr } from '../hooks/forge'
import { prTextOf } from '../hooks/pill'
import type { GitInfo } from '../types'

const GIT: Record<string, string> = {
  'rev-parse': '/w/GTI-273-foo\n/repo/.git/worktrees/GTI-273-foo\n/repo/.git\nfeat/GTI-273-foo\n',
  status: '## feat/GTI-273-foo...origin/feat/GTI-273-foo [ahead 2]\nM  a.ts\n M b.ts\n?? c.ts\n',
  remote: 'git@bitbucket.org:team/app.git\n',
  // <head of the PR>...HEAD: no PR commits missing here, 2 local ones not pushed.
  'rev-list': '0\t2\n',
}

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

const ok = (stdout: string) => ({
  value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
})

const plain = (ansi: string) => ansi.replace(/\x1b\[[0-9;]*m/g, '')

// The engine beneath the mod: a dirty linked worktree of a Bitbucket repo,
// whose main checkout is /repo.
function fakeEngine(on: On) {
  const world = { written: new Map<string, string>() }
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('ui.log', () => ({ value: undefined }))
  on('session.cwd', () => ({ value: '/w/GTI-273-foo' }))
  on('session.id', () => ({ value: 'abc123' }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? '/home/me' : undefined }))
  on('fs.exists', (_$, e) => ({ value: e.path.endsWith('CLAUDE_COMMIT_MSG') }))
  on('fs.write', (_$, e) => {
    world.written.set(e.path, e.text)
    return { value: undefined }
  })
  // twg writes JSON to a temp file when piped; the file holds the PR.
  on('fs.read', (_$, e) => ({
    value: e.path === '/tmp/get.json' ? JSON.stringify(PR) : e.path === '/tmp/query.json' ? '[{"id":41}]' : '',
  }))
  on('process.run', (_$, e) => {
    const [cmd, sub = ''] = e.argv
    if (cmd === 'git') return ok(GIT[sub] ?? '')
    const file = e.argv.includes('get') ? '/tmp/get.json' : '/tmp/query.json'
    return ok(`output_files:\n  stdout: "${file}"\n`)
  })
  return world
}

test('the mod writes pills of the worktree and its PR for the status line', async ($, on) => {
  const clock = mock.clock(on)
  const world = fakeEngine(on)

  await $.session.start({ cwd: '/w/GTI-273-foo', surface: 'terminal', isInteractive: true })
  await clock.settle()

  const pills = world.written.get('/home/me/.cache/claude-workbench/abc123')
  expect(plain(pills ?? '')).toBe(
    '\ue0b6repo/GTI-273-foo 2 unpushed · 1/3 staged msg ready\ue0b4',
  )
})

test('the mod writes the width of the conversation column for the status line', async ($, on) => {
  const clock = mock.clock(on)
  const world = fakeEngine(on)
  on('ui.render', () => ({ type: 'Box', props: {}, children: [] }) as never)

  await $.ui.mount({
    plugin: 'workbench',
    surface: 'terminal',
    component: 'PromptHint',
    props: { isDraft: false, isWorking: false, hint: '' },
    viewport: { columns: 120, rows: 40 },
  })
  await clock.settle()

  expect(world.written.get('/home/me/.cache/claude-workbench/abc123.columns')).toBe('120\n')
})

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
