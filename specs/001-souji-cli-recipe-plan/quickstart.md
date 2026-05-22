# Quickstart: Souji CLI

**Feature**: 001-souji-cli-recipe-plan
**Audience**: First-time Souji user.

This is the path from `gem install souji` to a green plan-and-apply cycle on
your own machine. It also doubles as the integration smoke test
(`spec/integration/cli_quickstart_spec.rb`) — every step here should map to a
runnable test.

## Prerequisites

- Ruby >= 3.2.
- `git` on `$PATH` (required for the `git-worktree` recipe).
- *(Optional)* `docker` on `$PATH` if you want the `docker-image` recipe to do
  anything useful. Without docker, Souji will skip that recipe with a stderr
  warning rather than fail (FR-020).
- *(Optional)* `trash` (macOS, `brew install trash`) or `gio` (Linux, usually
  pre-installed with GNOME) for trash-based deletion. Without either, Souji
  falls back to hard-delete with a loud warning.

## Install

```bash
gem install souji
souji version
# => souji 0.1.0
```

## 1. Write your first scenario

Souji follows the XDG Base Directory Specification: scenarios live under
`$XDG_CONFIG_HOME/souji/scenario/` (defaulting to `~/.config/souji/scenario/`),
and generated plans land under `$XDG_CACHE_HOME/souji/` (defaulting to
`~/.cache/souji/`).

Create your first scenario at the conventional location:

```bash
mkdir -p ~/.config/souji/scenario
$EDITOR ~/.config/souji/scenario/weekly.rb
```

```ruby
# ~/.config/souji/scenario/weekly.rb
target File.expand_path("~/work")

recipe "git-worktree"
recipe "docker-image"
```

This says: scan `~/work` for abandoned worktrees and dangling docker images.

> If you prefer ad-hoc scenarios outside the config dir, you can keep the file
> anywhere and pass its path: `souji plan ./weekly.rb` or
> `souji plan ~/cleanups/weekly.rb`. The XDG path is just the default; any
> argument containing `/`, starting with `~`, or ending with `.rb` is treated
> as a filesystem path.

## 2. Generate a plan

```bash
souji plan weekly
```

Souji resolves the bare name `weekly` to `~/.config/souji/scenario/weekly.rb`,
runs the scenario read-only, and writes the plan to
`~/.cache/souji/weekly.soujiplan` (creating `~/.cache/souji/` if missing).

Expected output (stdout):

```text
wrote /Users/you/.cache/souji/weekly.soujiplan: 17 items across 2 recipes
```

If `docker` is not installed, you'll also see on stderr:

```text
[souji] recipe 'docker-image' skipped: command 'docker' not found
```

Nothing on your filesystem under `~/work` was changed — `souji plan` is
strictly read-only (FR-008).

## 3. Inspect the plan

`weekly.soujiplan` is a human-readable YAML file. Open it in your editor:

```bash
$EDITOR ~/.cache/souji/weekly.soujiplan
```

You'll see entries like:

```yaml
souji_plan_version: 1
souji_version: "0.1.0"
generated_at: "2026-05-22T13:45:01+09:00"
scenario:
  path: "/Users/you/cleanups/weekly.rb"
  content_sha256: "ab12..."
target_roots:
  - "/Users/you/work"
items:
  - id: "git-worktree:01HZQK2H4Z9YPC7A0F0F4F0F4F"
    recipe: "git-worktree"
    path: "/Users/you/work/repo-a/.git/worktrees/feat-x"
    reason: "Worktree marked prunable by git"
    size_bytes: 248932
    metadata:
      branch: "feat-x"
```

If anything looks wrong, **stop here**: delete `weekly.soujiplan` and edit your
scenario. You've lost nothing.

## 4. Dry-run apply (still safe)

```bash
souji apply weekly --dry-run
```

The bare name `weekly` resolves to `~/.cache/souji/weekly.soujiplan`. This
prints the same summary `apply` would, but does NOT delete anything and does
NOT prompt for confirmation. Use it to preview the final action set one more
time before committing.

## 5. Apply for real

```bash
souji apply weekly
```

You'll be prompted:

```text
Souji plan: /Users/you/.cache/souji/weekly.soujiplan
About to delete 17 items (estimated 412 MB):
  - git-worktree:    8 items
  - docker-image:    9 items
Proceed? [y/N]:
```

Type `y` + Enter to proceed. Anything else cancels with exit code 130.

As apply runs, you'll see JSONL lines on stderr:

```json
{"ts":"2026-05-22T13:50:00.123+09:00","item_id":"git-worktree:01HZ...","recipe":"git-worktree","path":"/.../feat-x","outcome":"trashed","duration_ms":42}
```

And finally a summary line:

```json
{"summary":true,"ts":"...","deleted":9,"trashed":8,"skipped":0,"failed":0,"total":17,"duration_ms":18342}
```

The same JSONL log is also written to a timestamped file under
`~/.local/state/souji/log/` so you can audit the apply later. Souji creates
this directory on demand:

```bash
ls ~/.local/state/souji/log/
# => 2026-05-22T13-50-00Z-weekly.jsonl
```

If you don't want a file (e.g. ephemeral CI), pass `--no-log-file`. To put the
log somewhere specific, pass `--log-file /path/to/log.jsonl`.

Exit code is 0 if everything succeeded.

## 6. (Optional) Run again

Run `souji plan weekly` immediately and you should see the new plan contains
zero items (everything you just cleaned is gone). This is the determinism
property at work (FR-006, SC-004).

## What success looks like

After step 5, you should observe:

- **Filesystem**: every path listed in the plan's `items[].path` is either
  gone or in the platform trash. Nothing else under `~/work` is touched.
- **Stdout**: the apply summary printed to stdout.
- **Stderr**: per-item JSONL events + the summary JSONL line.
- **Exit code**: `0` if all items processed without failure; `73` if one or
  more items failed (you'll find them as `outcome:"failed"` lines in the log).

## Common gotchas

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `[souji] recipe 'docker-image' skipped: command 'docker' not found` | docker isn't installed | Install Docker Desktop / docker engine, or remove the `recipe "docker-image"` line. |
| Apply exits 130 immediately after the prompt | You typed something other than `y` | Re-run; press `y`. |
| `Plan refers to path outside target_roots` (exit 66) | Someone hand-edited the plan file to add a foreign path | Don't do that. Regenerate the plan. |
| `Apply requires --yes when stdin is not a TTY` | Running under cron / CI / a pipe | Add `--yes`, but ONLY after a human reviewed the plan. |
| `Incompatible souji_plan_version` (exit 66) | Plan generated by a newer Souji than the one applying it | Upgrade the local Souji to at least the version recorded in `souji_version`. |

## Next steps

- See `contracts/scenario-dsl.md` for the full DSL surface (`with_targets`,
  recipe-specific params).
- See `contracts/cli-commands.md` for every flag.
- See `contracts/plan-yaml-schema.md` if you want to programmatically read or
  filter plans.
