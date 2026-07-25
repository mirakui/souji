# Souji

A Ruby CLI tool for cleaning up local-disk cruft on developer workstations.
You write a cleanup scenario in a Ruby DSL composed of named **recipes**, run
`souji plan` to get a human-readable YAML plan of everything that would be
deleted, and `souji apply` to actually delete it (with confirmation, per-item
re-verification, and an audit log).

## Quickstart

```bash
gem install souji

souji init                                 # writes ~/.config/souji/scenario/default.rb
$EDITOR ~/.config/souji/scenario/default.rb # uncomment the targets and recipes you want

souji plan                       # writes ~/.cache/souji/default.soujiplan
$EDITOR ~/.cache/souji/default.soujiplan   # review what would be deleted
souji apply --dry-run            # preview without prompting
souji apply                      # prompt for confirmation, then delete
```

`souji init` generates a fully commented-out template, so a freshly
initialized scenario proposes nothing until you edit it. Additional scenarios
are just more files in the same directory, addressed by name:

```bash
$EDITOR ~/.config/souji/scenario/weekly.rb
souji plan weekly                # writes ~/.cache/souji/weekly.soujiplan
souji apply weekly
```

See [`specs/001-souji-cli-recipe-plan/quickstart.md`](specs/001-souji-cli-recipe-plan/quickstart.md)
for the full first-time walkthrough.

While `souji plan` runs, it narrates the scenario, each recipe and each target
being scanned on stderr, leaving stdout for the final summary line:

```text
[souji] scenario /home/u/.config/souji/scenario/weekly.rb
[souji] targets: /home/u/work
[souji] [1/2] recipe git-worktree (targets: /home/u/work)
[souji]   scanning /home/u/work/some-repo
[souji] recipe git-worktree: 1 item
```

Pass `--quiet` to suppress it.

## Built-in recipes (v1)

| Recipe | Resource | Options | External command |
|---|---|---|---|
| `git-worktree` | Abandoned git worktrees: prunable ones always, merged or long-untouched ones on request | `merged:`, `merged_into:`, `fetch:`, `older_than_days:` | `git` |
| `terraform-provider` | Terraform provider cache entries unreferenced by any `.terraform.lock.hcl` under target_roots | `plugin_cache_dir:` | (none — pure filesystem) |
| `docker-image` | Dangling docker images | `older_than_days:` | `docker` |

Run `souji recipes` to see the live list with descriptions and options. Options
are keyword arguments on the `recipe` call, and a recipe accepts only the ones
it declares — `souji plan` rejects an unknown option (and an unknown recipe
name) before it scans anything.

### Finding worktrees you are done with

By default `git-worktree` proposes only what git itself calls `prunable`: a
registration whose directory has vanished. The bulkier kind of cruft is the
worktree still sitting on disk long after you stopped working in it. Two
independent rules go looking for those, and a run with both on returns the
union:

```ruby
recipe "git-worktree", merged: true                        # base ref auto-detected
recipe "git-worktree", merged: true, merged_into: "origin/master"
recipe "git-worktree", merged: true, fetch: true           # refresh the base ref first
recipe "git-worktree", older_than_days: 90                 # no commit in 90 days
recipe "git-worktree", merged: true, older_than_days: 90   # either one is enough
```

**`merged:`** — the branch is already contained in the base ref, so the work
shipped. The base ref comes from `refs/remotes/origin/HEAD`, falling back to
`origin/main` then `origin/master`; `merged_into:` overrides it. A repository
where none of those resolve keeps prunable detection and says on stderr why it
got no merged check.

**`older_than_days:`** — nothing has been committed on the worktree for that
many days, merged or not, which is how an abandoned spike gets reclaimed.
Deleting a worktree leaves its branch behind, so the commits survive; a
**detached HEAD that no ref points at** has no such anchor and is therefore
never proposed, with the reason on stderr.

Either way a worktree is only proposed when it is **not locked** and has **no
uncommitted changes to tracked files**. Untracked files (build output, `.env`)
do not disqualify it — which is why deleting one moves the directory to the
trash rather than running `git worktree remove --force`, and why `souji apply`
re-runs the whole judgement per item before touching anything.

`fetch: true` is the only thing in `souji plan` that touches the network. It
runs strictly non-interactively (`GIT_TERMINAL_PROMPT=0`, `ssh -o
BatchMode=yes -o ConnectTimeout=10`) so an expired credential can never leave
a plan hanging on a prompt, and a failed fetch just falls back to the cached
remote-tracking ref.

## XDG layout

| Default location | Purpose | Auto-created? |
|---|---|---|
| `$XDG_CONFIG_HOME/souji/scenario/<name>.rb` | User-authored scenarios | only by `souji init` |
| `$XDG_CACHE_HOME/souji/<name>.soujiplan` | Generated plan files | yes |
| `$XDG_STATE_HOME/souji/log/<UTC-ts>-<name>.jsonl` | Apply action logs | yes |

Defaults fall back to `~/.config`, `~/.cache`, `~/.local/state`.

Bare-name resolution: `souji plan weekly` resolves the argument under the XDG
config dir; `souji plan ./local.rb` (or any path containing `/`, starting with
`~`, or ending with `.rb`) is taken as a literal filesystem path.

Omitting the argument means `default`: `souji plan` is `souji plan default` and
`souji apply` is `souji apply default`.

## Safety model

- `souji plan` is structurally read-only — there is no code path from the plan
  subcommand to filesystem deletion — and offline, unless a recipe is given
  `fetch: true`.
- `souji apply` requires interactive `y/N` confirmation. Non-interactive
  operation requires `--yes`; without a TTY AND without `--yes`, apply
  refuses with exit code 130.
- `--dry-run` reports what would be deleted without deleting anything.
- Every deletion is preceded by per-item recipe re-verification — items that
  no longer qualify (e.g., a worktree that has been re-activated) are skipped
  with a reason in the action log.
- Plan items whose path is outside the plan's `target_roots` are rejected at
  plan load time (exit 66 before any deletion).
- Reversible deletions go through `Souji::Trash` (`trash` / `osascript` on
  macOS, `gio trash` on Linux). When no trash backend is available the tool
  warns loudly and falls back to hard-delete.

## Exit codes

| Code | Meaning |
|---|---|
| 0   | Success |
| 1   | Unexpected failure |
| 2   | Usage error (bad args / mutually exclusive flags) |
| 65  | Scenario error (syntax, unknown recipe, scope escape) |
| 66  | Plan error (incompatible version, scope violation) |
| 73  | Apply partial failure (at least one item failed to delete) |
| 130 | User cancelled (or non-TTY without `--yes`) |

## Development

```bash
bundle install
bundle exec rspec           # 221 examples by default (docker/perf tag-gated)
bundle exec rubocop
WITH_DOCKER=1 bundle exec rspec   # include docker integration tests
gem build souji.gemspec
```

The implementation plan, design contracts, and task breakdown live under
[`specs/001-souji-cli-recipe-plan/`](specs/001-souji-cli-recipe-plan/).

## License

MIT — see [LICENSE](LICENSE).

Copyright (c) 2026 Issei Naruta
