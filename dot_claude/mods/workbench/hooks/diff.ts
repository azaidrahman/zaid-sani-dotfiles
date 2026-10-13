import type { GitInfo } from '../types'

// The diff panel of Claude Code is the built-in mod cc-plugin-diff.

// The panel keeps the base of the diff for each repository in its store, as
// `base:<top level>`. Its bases are "session" (the edits of this session),
// "uncommitted" and "branch" (all since the branch left the default branch).
// This answers what a read of a key gives: the branch base until the person
// picks one.
export function storedValueFor(key: string, stored: unknown): unknown {
  return stored === undefined && /^base:\//.test(key) ? 'branch' : stored
}

export type GitCall = { argv: readonly string[]; cwd: string | undefined }

// The diff panel finds its repository only when the session starts (and on
// /clear or /resume). So after the session moves into a worktree, it still
// runs git in the main checkout, as `git --git-dir=<main>/.git
// --work-tree=<main> ...` in the directory of the main checkout. This sends
// such a call to the worktree of the session instead.
export function gitCallFor(git: GitInfo | null, call: GitCall): GitCall {
  if (call.argv[0] !== 'git' || !git?.isLinked) return call
  const argv = call.argv.map(arg =>
    arg === `--git-dir=${git.mainRoot}/.git`
      ? `--git-dir=${git.gitDir}`
      : arg === `--work-tree=${git.mainRoot}`
        ? `--work-tree=${git.top}`
        : arg,
  )
  const cwd = call.cwd === git.mainRoot ? git.top : call.cwd
  return { argv, cwd }
}
