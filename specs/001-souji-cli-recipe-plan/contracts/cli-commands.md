# CLI Commands Contract

**Feature**: 001-souji-cli-recipe-plan
**Date**: 2026-05-22

This contract is the public surface of the `souji` binary. Changes here are
breaking changes to users.

## Global synopsis

```text
souji <subcommand> [args...] [options...]
```

Subcommands: `plan`, `apply`, `help`, `version`.

## Exit codes

The same code-space applies to every subcommand:

| Code | Meaning |
|------|---------|
| 0    | Success — the requested operation completed, including the empty-result case. |
| 1    | Unexpected failure — bug, IO error, recipe crash, anything not covered below. |
| 2    | Usage error — bad arguments, unknown subcommand, malformed flag. |
| 65   | Scenario error — scenario file failed to evaluate (syntax error, unknown recipe). |
| 66   | Plan error — plan file is malformed, refers to an incompatible schema version, or contains scope violations. |
| 73   | Apply partial failure — apply completed but at least one item failed (FR-017). |
| 130  | Cancelled by user — confirmation prompt declined, or process interrupted. |

Numeric choices follow Unix sysexits.h where reasonable (65=EX_DATAERR for
scenario errors; 66=EX_NOINPUT-ish for plan errors; 73=EX_CANTCREAT-adjacent for
partial-write semantics).

## Name resolution (applies to `plan` and `apply`)

The `<scenario>` argument of `plan` and the `<plan-file>` argument of `apply`
follow the same resolution rule (spec FR-007a):

1. **Path-shaped** — argument contains `/`, OR starts with `~`, OR ends with
   `.rb` (scenarios) / `.soujiplan` (plans) → treated as a filesystem path,
   relative paths resolved against CWD.
2. **Bare name** — everything else → looked up under the user's XDG directory:
   - Scenarios: `$XDG_CONFIG_HOME/souji/scenario/<name>.rb`, default
     `$XDG_CONFIG_HOME` to `~/.config`.
   - Plans: `$XDG_CACHE_HOME/souji/<name>.soujiplan`, default
     `$XDG_CACHE_HOME` to `~/.cache`.

Missing file ⇒ usage error (exit code 2) with stderr listing the path that
was tried.

## Subcommand: `souji plan`

**Synopsis**:

```text
souji plan <scenario> [-o <plan-file>] [--target-root <path>]... [--log-file <path>]
```

**Arguments**:

- `<scenario>` (required, positional) — name or filesystem path to a Ruby DSL
  scenario file. See "Name resolution" above. Examples:
  - `souji plan weekly` → `~/.config/souji/scenario/weekly.rb`
  - `souji plan ./weekly.rb` → CWD-relative path
  - `souji plan ~/cleanups/weekly.rb` → absolute path

**Options**:

- `-o, --output <plan-file>` — destination for the YAML plan file. Accepts the
  same name/path resolution: a bare name is interpreted as
  `$XDG_CACHE_HOME/souji/<name>.soujiplan`; a path-shaped value is used as-is.
  **Default**: when `<scenario>` was bare (e.g. `weekly`), defaults to
  `$XDG_CACHE_HOME/souji/<name>.soujiplan`; when `<scenario>` was a path,
  defaults to `$XDG_CACHE_HOME/souji/<scenario-basename-without-ext>.soujiplan`
  (per spec FR-007b). Souji creates `$XDG_CACHE_HOME/souji/` on demand if
  missing.
- `--target-root <path>` (repeatable) — additional target roots to merge with
  whatever the scenario declares. Provided for one-off ad-hoc use; ordinary
  workflows declare targets inside the scenario.
- `--log-file <path>` — duplicate stderr diagnostics to this file. The plan
  phase does not emit an action log (no actions are taken), but recipe-level
  diagnostics (skipped recipes, scope warnings) go here too.
- `--quiet` — suppress per-recipe progress on stderr. The plan file is still
  written and the summary still goes to stdout.

**Behavior**:

1. Load and `instance_eval` the scenario file (R6).
2. Resolve `target_roots` (scenario-declared ∪ `--target-root` flags).
3. For each `RecipeInvocation` in order:
   - Probe `required_external_commands` (R8). If any missing, emit
     `[souji] recipe '<name>' skipped: command '<cmd>' not found` to stderr
     and skip (FR-020).
   - Otherwise call `Recipe#enumerate(targets, params)` and collect candidates.
4. Build a `Plan` value object, write YAML to `-o`.
5. Print a one-line summary to stdout: `wrote <plan-file>: <N> items across <M> recipes`.

**Side effects**: writes the plan file. No other filesystem mutation under the
target roots (FR-008, SC-003).

**Exit codes used**: 0, 1, 2, 65.

## Subcommand: `souji apply`

**Synopsis**:

```text
souji apply <plan-file> [--yes] [--dry-run] [--log-file <path> | --no-log-file]
```

**Arguments**:

- `<plan-file>` (required, positional) — name or path of a previously generated
  plan file. See "Name resolution" above. Examples:
  - `souji apply weekly` → `~/.cache/souji/weekly.soujiplan`
  - `souji apply ./weekly.soujiplan` → CWD-relative path
  - `souji apply /tmp/test.soujiplan` → absolute path

**Options**:

- `--yes` — proceed without the interactive y/N prompt. Required for
  non-interactive contexts (cron, CI). Without `--yes` AND without a TTY, apply
  refuses with exit code 130 to prevent silent destructive automation.
- `--dry-run` — report what would be deleted without deleting anything. The
  confirmation prompt is bypassed. Exit code reflects whether the dry-run
  succeeded, not whether items were "applied".
- `--log-file <path>` — override the action log destination. Writes the JSONL
  log to `<path>` instead of the XDG default (see "Action log default
  destination" below). Stderr emission is unchanged.
- `--no-log-file` — suppress file output entirely; emit the action log only
  to stderr. Mutually exclusive with `--log-file` (passing both → exit 2).

**Behavior**:

1. Load `<plan-file>`, validate `souji_plan_version`.
2. Scope-check every `PlanItem.path` against `target_roots` (FR-016, FR-019).
   Any violation aborts apply with exit code 66 — even before the confirmation
   prompt.
3. Print summary to stdout (per-recipe item counts, estimated total size).
4. Confirmation gate (R9).
5. For each item: `Recipe#verify` → if `:ok`, `Recipe#delete`. Log each
   outcome as JSONL to stderr.
6. Emit summary line to stderr.
7. Exit 0 if all items deleted or skipped; 73 if at least one failed.

**Important non-behaviors** (FR-011a):

- Apply MUST NOT load, parse, or hash the scenario file.
- Apply MUST NOT call any recipe's `enumerate` method.
- The only recipe methods apply calls are `verify` and `delete`.

**Action log default destination** (spec FR-017a):

Without `--log-file` or `--no-log-file`, `apply` writes the JSONL action log
to a file under `$XDG_STATE_HOME/souji/log/` while also streaming it to
stderr. Filename format: `<UTC-timestamp>-<plan-basename>.jsonl` where:

- `<UTC-timestamp>` is the apply invocation time in `YYYY-MM-DDTHH-MM-SSZ`
  form (colons replaced with dashes for filesystem safety; always UTC so
  filenames sort lexicographically).
- `<plan-basename>` is the plan file's basename with `.soujiplan` stripped.

Example: `~/.local/state/souji/log/2026-05-22T13-50-00Z-weekly.jsonl`.

Souji creates `$XDG_STATE_HOME/souji/log/` on demand. If creation fails (read-
only filesystem, permission denied), apply emits a one-line warning to stderr
and continues with stderr-only logging — log persistence is best-effort and
MUST NOT block the actual deletion work (per spec Edge Case "Log directory
unwritable").

Log files are not rotated or pruned by Souji v1. Users who want this can
author a Souji scenario that targets `~/.local/state/souji/log/`.

**Exit codes used**: 0, 1, 2, 66, 73, 130.

## Subcommand: `souji help [<topic>]`

Standard Thor help. `souji help` lists subcommands; `souji help plan` /
`souji help apply` show per-command usage. `souji help recipes` prints the
recipe registry (recipe name + one-line description).

**Exit codes**: 0.

## Subcommand: `souji version`

Prints `souji <VERSION>` and exits 0. Also available as `souji --version`.

## stdout / stderr separation

| Stream | Content |
|--------|---------|
| stdout | Primary deliverable: confirmation summary (`apply`), final one-liner (`plan`). Suitable for piping. |
| stderr | All diagnostics: progress, recipe-skipped warnings, per-item JSONL action log, scope warnings. The action log is ALSO mirrored to a file under `$XDG_STATE_HOME/souji/log/` by default (FR-017a). |

Rule of thumb: anything a downstream script might want to parse goes on stdout;
anything a human reads while watching the command run goes on stderr.

## Examples (informational)

```bash
# --- Idiomatic flow with XDG conventions ---

# Put your scenario at ~/.config/souji/scenario/weekly.rb (one-time setup)
mkdir -p ~/.config/souji/scenario
$EDITOR ~/.config/souji/scenario/weekly.rb

# Generate plan: reads scenario by name, writes ~/.cache/souji/weekly.soujiplan
souji plan weekly

# Review the plan (it's YAML)
$EDITOR ~/.cache/souji/weekly.soujiplan

# Apply by name (reads the plan from the cache)
souji apply weekly

# Non-interactive apply (CI / cron)
souji apply weekly --yes

# Dry-run
souji apply weekly --dry-run


# --- Ad-hoc / fully-pathed flow (no XDG involvement) ---

# Generate from an explicit path; default output still lands in XDG cache
souji plan ~/cleanups/weekly.rb

# Or pin the output path explicitly
souji plan ~/cleanups/weekly.rb -o ./local-weekly.soujiplan

# Apply from a CWD-relative plan path
souji apply ./local-weekly.soujiplan
```
