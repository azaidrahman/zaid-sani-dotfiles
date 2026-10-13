import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { GitInfo, PrInfo } from '../types'
import { gitCallFor, storedValueFor } from './diff'
import { GITHUB_FIELDS, bitbucketPr, dirsOf, forgeOf, githubPr } from './forge'
import { DEFAULT_BRANCHES, prTextOf } from './pill'

// The PR text for the hint row. A render hook reads it, and a write redraws
// the row.
const prText = atom({ plugin: 'workbench', key: 'prText' } as const, '')

// The mod reads the PR of the branch (on GitHub or Bitbucket) and shows its
// state under the prompt. The status line builds the git pill itself. The mod
// also makes the diff panel follow the session into a worktree.

// The PR is fetched again after this long, or at once when the branch changes
// or a command touches the remote.
const PR_TTL_MS = 3 * 60_000
const REMOTE_COMMAND = /\b(git\s+push|gh\s+pr|twg\s+(bb|bitbucket)|pull-requests|prs\s)/

async function configDir($: EngineInterface): Promise<string> {
  return (await $.env.get('XDG_CONFIG_HOME')) || `${await $.env.get('HOME')}/.config`
}

// ${XDG_CONFIG_HOME:-~/.config}/claude-workbench/bitbucket-dirs (see dirsOf).
async function bitbucketDirs($: EngineInterface): Promise<string[]> {
  const text = await $.fs.read(`${await configDir($)}/claude-workbench/bitbucket-dirs`).catch(() => '')
  return dirsOf(typeof text === 'string' ? text : '', (await $.env.get('HOME')) ?? '')
}

async function readGit($: EngineInterface): Promise<GitInfo | null> {
  const cwd = await $.session.cwd()
  const paths = await $.process.run(
    ['git', 'rev-parse', '--path-format=absolute', '--show-toplevel', '--git-dir', '--git-common-dir', '--abbrev-ref', 'HEAD'],
    { cwd },
  )
  if (paths.exitCode !== 0) return null
  const [top = '', gitDir = '', commonDir = '', branch = 'HEAD'] = paths.stdout.trim().split('\n')

  const [status, remote, hasCommitMsg, hasPrMsg, dirs] = await Promise.all([
    $.process.run(['git', 'status', '--porcelain=v1', '--branch'], { cwd }),
    $.process.run(['git', 'remote', 'get-url', 'origin'], { cwd }),
    $.fs.exists(`${gitDir}/CLAUDE_COMMIT_MSG`),
    $.fs.exists(`${gitDir}/CLAUDE_PR_MSG`),
    bitbucketDirs($),
  ])

  const [head = '', ...files] = status.stdout.split('\n').filter(Boolean)
  return {
    worktree: top.split('/').pop() ?? top,
    branch,
    isLinked: gitDir !== commonDir,
    top,
    gitDir,
    mainRoot: commonDir.replace(/\/\.git$/, ''),
    staged: files.filter(f => f[0] !== ' ' && f[0] !== '?').length,
    changed: files.length,
    ahead: Number(/ahead (\d+)/.exec(head)?.[1] ?? 0),
    behind: Number(/behind (\d+)/.exec(head)?.[1] ?? 0),
    hasCommitMsg,
    hasPrMsg,
    forge: forgeOf(remote.stdout.trim(), top, dirs),
  }
}

// twg writes bare JSON to a terminal, but into a pipe it writes a YAML
// envelope and puts the JSON in a temp file named by `stdout:`.
async function twgJson($: EngineInterface, cwd: string, args: string[]): Promise<any> {
  const run = await $.process.run(['twg', ...args, '-o', 'json'], { cwd, timeoutMs: 30_000 })
  const out = run.stdout.trim()
  if (out.startsWith('{') || out.startsWith('[')) return JSON.parse(out)
  if (/^ok: false/m.test(out)) {
    throw new Error(/^\s*message: "(.*)"$/m.exec(out)?.[1] ?? 'twg failed')
  }
  const file = /^\s*stdout: "(.*)"$/m.exec(out)?.[1]
  if (!file) throw new Error(run.stderr.trim() || 'twg gave no output')
  return JSON.parse(await $.fs.read(file))
}

async function readBitbucketPr($: EngineInterface, cwd: string, branch: string): Promise<PrInfo> {
  let found: any[] = []
  for (const state of ['OPEN', 'MERGED', 'DECLINED']) {
    found = await twgJson($, cwd, ['bb', 'prs', 'query', '--source', branch, '--state', state, '-n', '1'])
    if (found.length) break
  }
  const id = found[0]?.id
  if (id === undefined) return { kind: 'none' }
  return bitbucketPr(await twgJson($, cwd, ['bb', 'prs', 'get', String(id)]))
}

// `gh pr view <branch>` finds the PR of the branch in any state. It exits
// non-zero when the branch has none.
async function readGithubPr($: EngineInterface, cwd: string, branch: string): Promise<PrInfo> {
  const run = await $.process.run(['gh', 'pr', 'view', branch, '--json', GITHUB_FIELDS], { cwd, timeoutMs: 30_000 })
  if (run.exitCode !== 0) {
    if (/no pull requests found/i.test(run.stderr)) return { kind: 'none' }
    throw new Error(run.stderr.trim() || 'gh failed')
  }
  return githubPr(JSON.parse(run.stdout))
}

// Compare HEAD with the head of the PR: `<pr>...HEAD` counts the commits
// on each side. It fails when the head of the PR is not in the repository.
async function readSync($: EngineInterface, headSha: string): Promise<{ ahead: number; behind: number } | null> {
  if (!/^[0-9a-f]{7,64}$/.test(headSha)) return null
  const run = await $.process.run(['git', 'rev-list', '--left-right', '--count', `${headSha}...HEAD`], {
    cwd: await $.session.cwd(),
  })
  const [behind, ahead] = run.stdout.trim().split(/\s+/).map(Number)
  return run.exitCode === 0 && ahead !== undefined && behind !== undefined ? { ahead, behind } : null
}

async function readPr($: EngineInterface, info: GitInfo): Promise<PrInfo> {
  const cwd = await $.session.cwd()
  return info.forge === 'github' ? readGithubPr($, cwd, info.branch) : readBitbucketPr($, cwd, info.branch)
}

let git: GitInfo | null = null
let pr: PrInfo | null = null
let prKey = ''
let prFetchedAt = 0
let isBusy = false
let queued: { forcePr: boolean } | null = null

// The PR text goes to the hint row of Claude Code (see the PromptHint hook).
async function showPrText($: EngineInterface): Promise<void> {
  // Claude Code links only a GitHub PR in the hint row.
  const text = prTextOf(pr, git?.forge !== 'github')
  await update($, prText, () => text)
}

async function refresh($: EngineInterface, forcePr: boolean): Promise<void> {
  if (isBusy) {
    queued = { forcePr: forcePr || (queued?.forcePr ?? false) }
    return
  }
  isBusy = true
  try {
    git = await readGit($)
    // The PR belongs to a branch of one repository.
    const key = git?.forge && !DEFAULT_BRANCHES.has(git.branch) ? `${git.mainRoot}:${git.branch}` : ''
    const now = await $.clock.now()
    const isStale = now - prFetchedAt > PR_TTL_MS
    if (!git || !key) {
      pr = null
    } else if (forcePr || key !== prKey || isStale) {
      if (key !== prKey) pr = null
      prFetchedAt = now
      // Show the PR state at once; the PR follows when the forge answers.
      await showPrText($)
      pr = await readPr($, git).catch(
        (err: unknown): PrInfo => ({ kind: 'error', message: String((err as Error)?.message ?? err) }),
      )
      if (pr.kind === 'error') $.ui.log(`workbench: PR read failed: ${pr.message}`, { to: 'debug' })
    }
    // Local commits change more often than the PR, so compare on each refresh.
    if (pr?.kind === 'pr') pr = { ...pr, sync: await readSync($, pr.headSha) }
    prKey = key
    await showPrText($)
  } catch (err) {
    $.ui.log(`workbench: refresh failed: ${String(err)}`, { to: 'debug' })
  } finally {
    isBusy = false
    const again = queued
    queued = null
    if (again) void refresh($, again.forcePr)
  }
}

// Run the refresh off the dispatch, so that a slow forge call never holds a
// tool call or the end of a turn.
function schedule($: EngineInterface, forcePr = false): void {
  $.clock.after(0, () => refresh($, forcePr))
}

export const register: Register = on => {
  // The git calls of the diff panel pass through this hook (see gitCallFor).
  // The panel opens by itself when its repository has changes, so this mod
  // does not open it.
  on('process.run', async ($, e, next) => {
    const call = gitCallFor(git, { argv: e.argv, cwd: e.init?.cwd })
    if (call.argv === e.argv && call.cwd === e.init?.cwd) return next(e)
    return next({ ...e, argv: call.argv, init: { ...e.init, cwd: call.cwd } })
  })

  // The diff panel keeps its base for each repository (see storedValueFor).
  on('store.get', async ($, e, next) => {
    const result = await next(e)
    if (!('value' in result)) return result
    const value = storedValueFor(e.key, result.value)
    return value === result.value ? result : { value }
  })

  // The hint line under the prompt draws again when the PR text changes (it
  // reads prText). It ends with the state of the PR, after the "PR #<n>" link
  // that Claude Code puts in it.
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    const text = await read($, prText)
    if (!text || e.props.tail) return next(e)
    return next({ ...e, props: { ...e.props, tail: text } })
  })

  on('session.start', async ($, e, next) => {
    schedule($)
    $.clock.every(PR_TTL_MS, () => refresh($, false))
    await $.command.register({
      name: 'pr-refresh',
      description: 'Read the git state and the PR of the branch again.',
    })
    await $.command.register({
      name: 'pr-copy',
      description: 'Copy the URL of the PR of the branch to the clipboard (works over SSH).',
    })
    return next(e)
  })

  on('command.run', { command: 'pr-refresh' }, async $ => {
    await refresh($, true)
    return { text: 'Refreshed the PR of the branch.' }
  })

  // The terminal copies with OSC 52, so the URL reaches the clipboard of the
  // machine you type on, also when Claude Code runs over SSH.
  on('command.run', { command: 'pr-copy' }, async $ => {
    if (pr?.kind !== 'pr' || !pr.url) return { text: 'This branch has no PR.' }
    const copied = await $.ui.copy({ text: pr.url })
    return { text: copied.isCopied ? `Copied ${pr.url}` : `Could not copy (${copied.reason}): ${pr.url}` }
  })

  on('prompt.submit', ($, e, next) => {
    schedule($)
    return next(e)
  })

  on('turn.complete', ($, e, next) => {
    schedule($)
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const result = await next(e)
    schedule($, REMOTE_COMMAND.test(e.command))
    return result
  })

  on('tool.call', { tool: 'Edit' }, async ($, e, next) => {
    const result = await next(e)
    schedule($)
    return result
  })

  on('tool.call', { tool: 'Write' }, async ($, e, next) => {
    const result = await next(e)
    schedule($)
    return result
  })

  on('tool.call', { tool: 'EnterWorktree' }, async ($, e, next) => {
    const result = await next(e)
    schedule($)
    return result
  })

  on('tool.call', { tool: 'ExitWorktree' }, async ($, e, next) => {
    const result = await next(e)
    schedule($)
    return result
  })
}
