# Feature Spec: merged and stale worktree detection for the `git-worktree` recipe

**Status**: implemented
**Date**: 2026-07-25
**Affects**: `lib/souji/recipes/git_worktree.rb`, `spec/support/git_repo_factory.rb`,
`spec/integration/recipes/git_worktree_spec.rb`, `spec/integration/perf_spec.rb`, `README.md`

## Problem

The `git-worktree` recipe only proposes worktrees that git itself flags as
`prunable` — that is, registrations whose directory has vanished from disk. That
covers accidents, not the dominant source of worktree cruft on a developer
workstation: worktrees whose branch has already been merged into the default
branch and whose directory is still sitting there consuming disk.

A shell prototype (`list_worktrees.sh`) demonstrates the missing judgement: for
every non-main worktree, ask whether its HEAD is an ancestor of `origin/main`.
If it is, the work is done and the worktree is dead weight.

Merge status is not the whole story, though: a spike that was abandoned without
ever merging occupies exactly as much disk. Commit age catches those.

## Goals

- Detect merged-but-still-present worktrees, opt-in per scenario.
- Detect worktrees nothing has been committed to in N days, opt-in and
  independent of merge status.
- Never propose a worktree that still holds work the user could lose.
- Keep `souji plan` free of network side effects unless the scenario asks for them.
- Keep the existing behaviour byte-identical for scenarios that do not opt in.

## Non-goals

- Detecting stale branches that have no worktree. Out of scope for this recipe.
- Age measured from anything other than the last commit — file mtimes, reflog
  activity, directory ctime. "Last commit" is the signal.
- Configuring the remote separately from the base ref. `merged_into: "upstream/main"`
  already expresses that.

## Recipe parameters

Four new declared params, all off by default. `merged_into:` and `fetch:` are
inert unless `merged:` is truthy; `older_than_days:` stands on its own.

| Param | Type | Default | Meaning |
|---|---|---|---|
| `merged` | boolean | `false` | Enable merged-worktree detection. |
| `merged_into` | string | auto | Base ref to test ancestry against. Overrides auto-detection. |
| `fetch` | boolean | `false` | Refresh the base ref from its remote before judging. |
| `older_than_days` | integer | none | Enable age detection at this threshold. |

```ruby
recipe "git-worktree"                                       # unchanged: prunable only
recipe "git-worktree", merged: true                         # + merged, base auto-detected
recipe "git-worktree", merged: true, merged_into: "origin/master"
recipe "git-worktree", merged: true, fetch: true
recipe "git-worktree", older_than_days: 90                  # + no commit in 90 days
recipe "git-worktree", merged: true, older_than_days: 90    # union of both rules
```

`merged:` and `older_than_days:` are independent reasons to propose a worktree,
not a conjunction. A merged worktree is proposed however recently it was
committed to; a stale one is proposed whether or not it ever merged. When both
rules match, the item is labelled `merged` — the more specific fact.

Unknown params are already rejected at plan time by `Scenario#validate!`, so a
typo such as `merged_to:` fails before any scanning.

## Detection algorithm

For each git repository found under the target roots:

1. Run `git -C <repo> worktree list --porcelain` and parse it. The parser gains
   `locked` (currently dropped on the floor) alongside the existing
   `worktree` / `HEAD` / `branch` / `detached` / `prunable` handling.
2. Treat the **first porcelain record as the main worktree** and never propose
   it. git documents that the main worktree is listed first, followed by the
   linked worktrees. This replaces the current `entry[:worktree] != repo`
   comparison, which misjudges repositories reached through a symlink or a
   path that macOS normalises (`/tmp` → `/private/tmp`).
3. Skip any entry marked `locked`. `git worktree lock` is an explicit "hands
   off" from the user, and `git worktree remove --force` refuses a locked
   worktree anyway (it demands `--force --force`, verified on git 2.52.0).
   In practice git never marks a locked worktree `prunable`, so this guard is
   defensive on the prunable path and load-bearing on the merged path.
4. `prunable` entries become candidates, exactly as today.
5. Every remaining entry must have its directory on disk and a clean working
   tree (`git status --porcelain --untracked-files=no` empty) before either
   opt-in rule may claim it. Untracked files are deliberately *not*
   disqualifying — build output and `.env` files would otherwise mask every
   finished worktree. They are instead the reason deletion goes through the
   trash (see below).
6. The merged check runs first, then the age check.

### Merged check

Per repository, resolved once and memoised:

**Base ref resolution**

1. `merged_into:` if the scenario supplied it.
2. Otherwise `git symbolic-ref refs/remotes/origin/HEAD`, which yields
   `refs/remotes/origin/main`, `refs/remotes/origin/master`, or whatever the
   clone actually defaults to.
3. Otherwise the first of `origin/main`, `origin/master` that
   `git rev-parse --verify -q <ref>^{commit}` accepts.
4. If nothing resolves, the repository gets no merged detection. Prunable
   detection still runs, and `progress` reports the reason.

**Optional fetch**

When `fetch: true`, derive the remote and branch from the resolved base ref
(`refs/remotes/<remote>/<branch>`) and run `git fetch <remote> <branch>` once
per repository, with:

- `GIT_TERMINAL_PROMPT=0`
- `GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"`

Without those, a repository with an expired credential hangs `souji plan` on an
interactive prompt. A failed fetch is not fatal: the run continues against the
cached remote-tracking ref and `progress` says so.

**Per-worktree judgement**

A worktree is a merged candidate when
`git -C <repo> merge-base --is-ancestor <worktree HEAD> <base commit>` succeeds.

Detached-HEAD worktrees are eligible: ancestry is judged on the commit, so a
detached worktree whose commit is already in the base loses nothing.

### Age check

The age is whole days between now and the committer date of the worktree's
HEAD (`git show --no-patch --format=%ct`). A worktree is a stale candidate when
that age is at least `older_than_days:` — **and** its commits are anchored.

Anchoring is the safety property that makes this rule tolerable on unmerged
work. Deleting a worktree removes the directory and the `.git/worktrees/`
registration; it does **not** delete `refs/heads/<branch>`, so a worktree on a
branch loses nothing recoverable. A detached HEAD has no such anchor: if no ref
contains the commit (`git for-each-ref --contains <sha> --count=1` is empty),
removing the worktree hands the commit to gc. Those are never proposed, and
`progress` says why.

Merged detached worktrees are unaffected: the base ref contains their commit,
so `for-each-ref --contains` finds it.

## Plan items

Every item carries `metadata.detection` (`"prunable"`, `"merged"`, `"stale"`),
which is what lets `#verify` and `#delete` re-judge at apply time without
re-reading the scenario, plus the existing `repo` / `branch` / `head`.

`size_bytes` is the recursive size of the worktree directory, so the plan shows
how much disk the deletion reclaims. Prunable items keep `size_bytes: nil`
because their directory is already gone.

| detection | `reason` | extra metadata |
|---|---|---|
| `prunable` | `Worktree marked prunable by git: <git's reason>` | — |
| `merged` | `Branch feat-x is merged into origin/main` | `merged_into` |
| `stale` | `Branch feat-x last committed 132 days ago` | `older_than_days`, `last_commit_at` |

Detached worktrees say `Detached HEAD <short sha>` where the table says
`Branch feat-x`.

## Verify

`#verify` re-runs the same judgement at apply time, **never fetching**, which is
the guard against deleting a worktree the user resumed between `plan` and
`apply`. It confirms the owning repository still exists and the worktree is
still registered and unlocked, then, by `detection`:

- `prunable` — git still calls it prunable.
- `merged` — directory present, recorded base ref still resolves, HEAD still an
  ancestor of it, working tree still clean.
- `stale` — directory present, last commit still older than the recorded
  threshold, still anchored, working tree still clean.

Any failure returns `[:skip, <reason>]`.

Because both halves must agree, the rules live in one place —
`Souji::Git::WorktreePolicy` — which `#enumerate` and `#verify` both drive.

## Delete

- **Prunable** (directory already gone): unchanged — trash the matching
  `.git/worktrees/<name>/` metadata directory.
- **Merged or stale** (directory present): `Souji::Trash.dispose(<worktree
  path>)`, then `git -C <repo> worktree prune` to drop the now-dangling
  registration.

Not `git worktree remove --force`. Because untracked files are not a
disqualifier, a hard delete could destroy unrecoverable local-only files;
routing through the trash keeps the deletion reversible, which is what the
README's safety model promises. Recovery is the documented
`git worktree prune` + `git worktree add <path> <branch>` dance.

If `Trash.dispose` fails, the registration is left alone and the item reports
`[:failed, ...]` — never a half-deleted state where the files are gone but git
still believes the worktree exists.

## Scan performance

`find_git_repos` prunes `node_modules`, `.terraform`, `.venv`, `vendor`, and
`bundle` while descending, mirroring the shell prototype. The current traversal
walks the full contents of every repository looking for nested `.git`
directories, and these five directories are where that time goes.

Nested repositories outside those directories are still discovered; the
traversal semantics are otherwise unchanged.

## Testing

Integration specs against real `git` subprocesses, per Constitution Principle IV.

`spec/support/git_repo_factory.rb` gains helpers:

- `add_remote_with_main(repo:)` — a local bare "origin" plus a pushed
  `origin/main` and `refs/remotes/origin/HEAD`, so ancestry is testable without
  a network.
- `commit_in_worktree(wt_path)` — a commit on the worktree's own branch. Its
  default filename is derived from the worktree path so that sibling worktrees
  of one repo do not stage identical content.
- `merge_branch_into_default!(repo:, branch:)` — merge and push, producing a
  genuinely merged branch.
- `sha_of(repo:, rev:)` and `stale_tracking_ref!(repo:, commit:)` — rewind a
  remote-tracking ref to simulate a clone that has not fetched since the branch
  moved on, which is how `fetch:` gets tested offline.
- `dirty_worktree!(path)` / `add_untracked_file!(path)` / `lock_worktree!`.
- `commit_in_worktree(path, days_ago:)` — backdates the commit. The timestamp
  is computed in Ruby and passed absolute, because `GIT_COMMITTER_DATE` rejects
  relative dates (`"120 days ago"` is a fatal error).
- `add_detached_worktree(repo:, wt_path:, commit:)` — a worktree with no branch
  of its own, for the anchoring cases.

Cases to cover:

- `merged:` absent → merged worktrees are not proposed (back-compat).
- `merged: true` → merged worktree proposed; unmerged worktree not proposed.
- Merged worktree with uncommitted tracked changes → not proposed.
- Merged worktree with only untracked files → proposed.
- Locked worktree → never proposed, by any rule.
- Main worktree → never proposed (it sits on the base ref, so merged detection
  would otherwise propose the repository itself).
- `merged_into:` override wins over `origin/HEAD`.
- Repository with no resolvable base ref → no merged items, no crash, prunable
  items still found.
- `fetch:` off misses an upstream merge the clone has not fetched; `fetch: true`
  sees it; an unreachable remote falls back to the cached ref with a note.
- `older_than_days:` absent → commit age is ignored (back-compat).
- Last commit past the threshold → proposed; inside it → not.
- Stale worktree dirty or locked → not proposed.
- Stale detached worktree with no ref containing its commit → not proposed,
  with the reason on stderr; one some ref contains → proposed.
- `merged:` and `older_than_days:` together → each worktree labelled by the rule
  that caught it.
- `#verify` skips a merged item after the worktree is dirtied, and after new
  unmerged commits land on its branch.
- `#verify` skips a stale item after a fresh commit resets its age.
- `#delete` trashes the directory and leaves no registration behind.
- perf spec extended with merged worktrees, still inside the 30 s budget.

Specs written after their implementation are mutation-checked (break one guard,
confirm the matching example fails) so they are known not to be vacuous.

## Documentation

- README's recipe table gains the four params, plus a section on the two opt-in
  rules and the note that `fetch:` is the only thing in `souji plan` that
  touches the network.
- The `souji init` template documents all four (a spec asserts the template
  never drifts from what the recipes declare — counted per declaration, so one
  recipe's entry cannot vouch for another's same-named param).
- `contracts/cli-commands.md` documents the new `Progress#note` narration line.

## Implementation notes

The git plumbing lives in `lib/souji/git/`, not in the recipe:

- `Command` — subprocess wrapper that answers nil/false instead of raising.
- `WorktreeList` — porcelain parsing, main-worktree-first.
- `BaseRef` — base ref resolution, non-interactive fetch, ancestry.
- `Commit` — commit age and "does any ref contain this?".
- `Registration` — the `.git/worktrees/<name>/` bookkeeping needed when a
  worktree has outlived its directory.
- `WorktreePolicy` — the rules themselves, driven by both `#enumerate` and
  `#verify` so the two cannot drift.

That split keeps the recipe inside the project's 150-line class budget and gives
each piece its own seam.
