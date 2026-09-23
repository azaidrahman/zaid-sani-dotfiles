# Core instructions

## Writing style: Simplified Technical English

ASD-STE100 Simplified Technical English is a controlled writing standard.
Aerospace and defense groups made it. It helps people write clear technical
text. Many readers are not native English speakers. Clear text helps them do
the work in a safe and correct way.

**Apply STE to technical writing.** This means:

- documentation, READMEs, and markdown files
- code comments and docstrings
- commit messages, PR descriptions, and ticket bodies
- runbooks, design docs, and instructions for other people

**Do not apply STE to** chat replies to me, or to code itself. Talk to me
normally. Write code in the idiom of the surrounding file.

### The rules

1. **Use approved words only.** The standard gives a word list. Each word has
   one meaning. The full dictionary is not here, so use the practical form:
   prefer the simplest word that is correct. Do not use a rare word when a
   common word works.
2. **Use one word for one idea.** Do not use two words for the same thing. If
   you call it a "job" in one line, do not call it a "task" in the next line.
   Keep the same term for the same thing in the whole document.
3. **Write short sentences.** Use 20 words or less for an instruction. Use 25
   words or less for descriptive text. One instruction per sentence.
4. **Use active voice.** Write "Turn the switch". Do not write "The switch must
   be turned".
5. **Write short paragraphs.** Keep one topic in each paragraph. Use 6 sentences
   or less.
6. **Use the imperative for steps.** Start each step with the action verb. Write
   "Run the migration". Do not write "The migration should now be run".
7. **Do not use noun clusters.** Three nouns in a row is too many. Write "the
   log of the build agent". Do not write "build agent log data".
8. **Write the condition first.** Write "If the build fails, check the logs". Do
   not write "Check the logs if the build fails".
9. **Do not omit words.** Keep articles and relative pronouns. Write "the file
   that you changed". Do not write "file you changed".
10. **Do not use jargon or slang.** Use the plain term. If a technical term is
    necessary, define it one time on first use.

### Examples

| Do not write | Write |
|---|---|
| The configuration file should be updated by the operator. | Update the configuration file. |
| Utilize the provided helper in order to instantiate the client. | Use the helper to make the client. |
| Deployment pipeline failure notification settings | The settings for notifications about a failure of the deployment pipeline |
| Check the token if authentication is rejected. | If authentication is rejected, check the token. |

### Conflicts with other rules

A repository CLAUDE.md, a skill, or a direct request from me wins over this
file. Some formats have a fixed shape. Keep that shape, and write STE inside it.

- Conventional commits keep `type(scope): subject`. Write the subject in STE.
- Ticket templates keep their headings. Write the body text in STE.

## Approval before git history changes

Do not commit, push, merge, or open a pull request without my approval.
This applies when the work is complete and the tests pass. It applies when
a skill tells you to commit. It applies when I approved the plan, because
approval of a plan is not approval of the commit.

Do this instead:

1. Stage the files.
2. Write the commit message to the message file (see below).
3. Show me the message and the list of staged files.
4. Stop, and wait for my answer.

If I ask you to commit, push, merge, or open a pull request, do it. A direct
request is the approval. One approval covers one action, and it does not
carry over to the next action or to a later commit.

### The message file

Always write the proposed commit message to this file:

```bash
"$(git rev-parse --absolute-git-dir)/CLAUDE_COMMIT_MSG"
```

The file is in the git directory, so git does not track it. Each worktree has
its own file. Replace the full contents each time you propose a message. Write
only the message text, with no comment lines.

I can edit the file in a tmux popup with `prefix+y`. The popup can also do the
commit. Thus, the file can change after you write it.

When I approve the commit, do these steps:

1. If the file does not exist, check `git log -1`. If I did the commit in the
   popup, do not commit again.
2. Read the file again. Do not use your earlier copy of the message.
3. Run `git commit -F <file>`.
4. If the commit succeeds, delete the file.

## Worktree policy

Use the current checkout for read-only work.

Use the current checkout for a small change only. A small change modifies one
existing file and has no behavior change, generated file, lock file, test, or
writing subagent.

Before any other write, create an isolated worktree.

- If the work has a Jira ticket, use the `start-ticket-worktree` skill.
- If the work has no Jira ticket, use the `start-worktree` skill.
- If the scope grows, stop writing in the current checkout. Start an isolated
  worktree before the next write.

After you create the worktree, move the session into it. Use the
`EnterWorktree` tool with the path that the skill reports.

A `cd` command does not move the session. The session stays in the old
directory. The `/diff` panel then shows no changes, because it reads the
repository of the session directory.

Skip this step if the skill opened a new tmux session or window in the
worktree. That session already has the correct directory.

One primary writing session owns each worktree. Do not send two writing agents
to the same worktree.

When agents write concurrently, use isolated task worktrees. The coordinator
does not edit shared files while writing agents run.

Use `finish-branch` to close a landed branch. It also closes ticketless
branches.
