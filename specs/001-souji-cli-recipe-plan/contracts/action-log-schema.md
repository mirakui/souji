# Action Log Schema Contract

**Feature**: 001-souji-cli-recipe-plan
**Date**: 2026-05-22

`souji apply` emits a JSON Lines (JSONL) action log: one JSON object per line.

**Destinations**:

- **stderr** — always. Streams the log in real time so users watching apply
  see progress.
- **File** — by default, `$XDG_STATE_HOME/souji/log/<UTC-timestamp>-<plan-basename>.jsonl`
  (defaulting `$XDG_STATE_HOME` to `~/.local/state`). The file destination
  can be overridden with `--log-file <path>` or suppressed with
  `--no-log-file`. See `contracts/cli-commands.md` for the full flag semantics.
- **Best-effort persistence**: if the default log file cannot be opened
  (read-only fs, permission denied, etc.), apply emits a one-line warning to
  stderr and continues with stderr-only emission. The audit trail being
  best-effort never blocks actual cleanup work (spec Edge Case "Log
  directory unwritable").

The log is append-safe (no in-place rewrites) so partial-failure mid-apply
still leaves a complete record of what happened up to the failure.

## Stream format

- Encoding: UTF-8.
- Each line: one JSON object, terminated by `\n`. No trailing comma, no
  surrounding brackets. Compatible with `jq -c` and standard JSONL tooling.
- Lines are emitted in real time as actions complete, not buffered to the end.

## Per-item line

Emitted once per plan item processed, regardless of outcome.

```json
{"ts":"2026-05-22T13:50:00.123+09:00","item_id":"git-worktree:01HZ...","recipe":"git-worktree","path":"/Users/naruta/work/repo-a/.git/worktrees/feat-x","outcome":"trashed","duration_ms":42}
```

### Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `ts` | string | yes | RFC 3339 timestamp with offset, millisecond precision. |
| `item_id` | string | yes | Matches the plan's `items[i].id`. |
| `recipe` | string | yes | Recipe name. |
| `path` | string | yes | Plan-item path (filesystem or synthetic URI). |
| `outcome` | string | yes | One of: `deleted`, `trashed`, `skipped`, `failed`. |
| `duration_ms` | integer | yes | Wall-clock duration of `verify` + `delete` for this item, in milliseconds. |
| `reason` | string | conditional | Required iff `outcome == "skipped"`. The reason returned by `Recipe#verify`. |
| `error` | string | conditional | Required iff `outcome == "failed"`. The error class + message. |

### Outcome semantics

| `outcome` | Meaning |
|---|---|
| `deleted` | Resource removed irreversibly via recipe-native mechanism (e.g., `docker image rm`, `git worktree remove`). |
| `trashed` | Resource moved to platform trash via `Souji::Trash`; user could in principle restore manually. |
| `skipped` | Recipe's `verify` returned `[:skip, reason]`. No deletion attempted. |
| `failed` | Recipe's `delete` returned `[:failed, error]`. Apply will exit with code 73 after the summary. |

## Terminal summary line

Emitted exactly once, at the end of apply (success or partial failure).

```json
{"summary":true,"ts":"2026-05-22T13:50:18.465+09:00","deleted":11,"trashed":4,"skipped":1,"failed":1,"total":17,"duration_ms":18342}
```

### Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `summary` | boolean | yes | Always `true`. Distinguishes summary from per-item lines. |
| `ts` | string | yes | Timestamp of summary emission. |
| `deleted` | integer | yes | Count of per-item lines with `outcome: deleted`. |
| `trashed` | integer | yes | Count with `outcome: trashed`. |
| `skipped` | integer | yes | Count with `outcome: skipped`. |
| `failed` | integer | yes | Count with `outcome: failed`. |
| `total` | integer | yes | Count of plan items. Equals `deleted + trashed + skipped + failed`. |
| `duration_ms` | integer | yes | Total apply wall-clock time, milliseconds. |

## Ordering guarantees

- Per-item lines appear in the same order as `items[]` in the plan file.
- The summary line is always the last line.
- No interleaving — `apply` is serial within a single process.

## Parsing recipe (informational)

```bash
# Count failures
souji apply weekly.soujiplan 2>&1 >/dev/null | jq -c 'select(.outcome=="failed")' | wc -l

# Total bytes trashed
souji apply weekly.soujiplan 2>apply.jsonl
jq -s '[ .[] | select(.outcome=="trashed") | .duration_ms ] | add' apply.jsonl
```

## Stability

The action log schema is part of the public contract. Any of the following are
breaking changes and require a major-version bump of Souji:

- Renaming or removing a field.
- Changing a field's type.
- Adding a new `outcome` value that consumers might not recognize (existing
  values stay valid).

Adding new optional fields is non-breaking.
