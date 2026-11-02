# ~/.config/git

Chezmoi-managed files that live alongside `~/.gitconfig`. Current contents:

| File | Purpose |
|---|---|
| `allowed-signers` | whitelist consumed by `gpg.ssh.allowedSignersFile` so `git log --show-signature` verifies commits locally |

## The credential helpers

`~/.gitconfig` sets the helpers for `github.com` and `bitbucket.org`:

```
helper =                                       # remove osxkeychain (Homebrew git)
helper = <home>/.local/bin/git-credential-op
```

`git-credential-op` reads the token from 1Password with `op-sa`. `op-sa` uses
a service-account token, and it works only while the op-sa window is open
(`op-sa unlock`). The helper keeps each token in the window, so each host
needs one read of 1Password in each window. When the window closes, the
tokens go away. Nothing goes in the keychain.

If the window is closed, the helper tells git to stop (`quit=1`). Then git
does not ask for a password, and it does not wait. Run `op-sa unlock`, and
push again.

### Worth knowing

- **Do not add a `cache` or `osxkeychain` helper.** Each one keeps the token
  after the window closes. Without the empty `helper =` line, osxkeychain
  answers first.
- **The rate limit is a rolling hour.** 1Password allows 1,000 reads in each
  hour for each service-account token. The hour starts at the first read, not
  at the top of the hour.
- **To get a rotated token,** do nothing. When a token fails, git calls
  `erase`, and the next push reads 1Password again. To start again from
  1Password at once, run `op-sa lock`, then `op-sa unlock`.

### The read budget

```
GitHub:     1 read in each window (credential)
Bitbucket:  2 reads in each window (credential + username)
+ the same again after each erase
```

Scripts that use `op-sa` (for example loops of `op-sa read`) use the same
budget, so keep them deliberate.
