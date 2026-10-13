/** The host of the `origin` remote, when the mod can read its PRs. */
export type Forge = 'github' | 'bitbucket'

export type GitInfo = {
  /** The basename of the working tree's top level. */
  worktree: string
  /** The branch, or 'HEAD' when detached. */
  branch: string
  /** True for a linked worktree, false for the main checkout. */
  isLinked: boolean
  /** The top level of the working tree, absolute. */
  top: string
  /** The git directory of the working tree, absolute. */
  gitDir: string
  /** The top level of the main checkout of the repository. */
  mainRoot: string
  staged: number
  changed: number
  ahead: number
  behind: number
  hasCommitMsg: boolean
  hasPrMsg: boolean
  forge: Forge | null
}

/** The 256-color numbers of the pill, from ~/.claude/palette.json. */
export type Palette = {
  surface: number
  surface_dim: number
  text: number
  dim: number
  ok: number
  warn: number
  crit: number
  merged: number
}

export type Build ='ok' | 'fail' | 'running' | null

export type PrState = 'open' | 'draft' | 'merged' | 'closed'

export type PrInfo =
  | { kind: 'none' }
  | { kind: 'error'; message: string }
  | {
      kind: 'pr'
      id: number
      state: PrState
      url: string
      /** The commit at the head of the PR (Bitbucket gives it short). */
      headSha: string
      /**
       * The commits of the worktree (HEAD) against the head of the PR:
       * `ahead` are local commits that the PR does not have yet, `behind` are
       * PR commits that the worktree does not have. Null when the head of the
       * PR is not in the local repository.
       */
      sync: { ahead: number; behind: number } | null
      approvals: number
      changesRequested: number
      reviewers: number
      openTasks: number
      comments: number
      build: Build
    }

declare module 'claude-code' {
  interface PluginState {
    workbench: { prText: string }
  }
}
