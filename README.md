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

| Recipe | Resource | External command |
|---|---|---|
| `git-worktree` | Abandoned git worktrees (HEAD-missing, marked prunable by git) | `git` |
| `terraform-provider` | Terraform provider cache entries unreferenced by any `.terraform.lock.hcl` under target_roots | (none — pure filesystem) |
| `docker-image` | Dangling docker images | `docker` |

Run `souji recipes` to see the live list with descriptions.

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
  subcommand to filesystem deletion.
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
bundle exec rspec           # 127 examples by default (docker tag-gated)
bundle exec rubocop
WITH_DOCKER=1 bundle exec rspec   # include docker integration tests
gem build souji.gemspec
```

The implementation plan, design contracts, and task breakdown live under
[`specs/001-souji-cli-recipe-plan/`](specs/001-souji-cli-recipe-plan/).

## License

MIT — see [LICENSE](LICENSE).

Copyright (c) 2026 Issei Naruta
