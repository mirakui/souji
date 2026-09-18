# Plan YAML Schema Contract

**Feature**: 001-souji-cli-recipe-plan
**Date**: 2026-05-22

This document defines the on-disk format for plan files produced by `souji plan`
and consumed by `souji apply`. The format is the user-facing contract for plan
files; changes to the schema MUST bump `souji_plan_version`.

## Top-level shape

```yaml
souji_plan_version: 1
souji_version: "0.1.0"
generated_at: "2026-05-22T13:45:01+09:00"
scenario:
  path: "/Users/naruta/cleanups/weekly.rb"
  content_sha256: "ab12cd34ef56...90"
target_roots:
  - "/Users/naruta/work"
  - "/Users/naruta/playground"
items:
  - id: "git-worktree:01HZQK2H4Z9YPC7A0F0F4F0F4F"
    recipe: "git-worktree"
    path: "/Users/naruta/work/repo-a/.git/worktrees/feat-x"
    reason: "Worktree marked prunable by git (last accessed > 30d ago)"
    size_bytes: 248932
    metadata:
      commit: "abc1234"
      branch: "feat-x"
      head_missing: true
  - id: "terraform-provider:01HZQK2H4Z9YPC7A0F0F4F0F50"
    recipe: "terraform-provider"
    path: "/Users/naruta/.terraform.d/plugin-cache/registry.terraform.io/hashicorp/aws/4.50.0/darwin_arm64"
    reason: "Provider version unreferenced by any .terraform.lock.hcl under target roots"
    size_bytes: 312828134
    metadata:
      namespace: "hashicorp"
      provider: "aws"
      version: "4.50.0"
  - id: "docker-image:01HZQK2H4Z9YPC7A0F0F4F0F51"
    recipe: "docker-image"
    path: "docker-image://sha256:e3f4a8..."
    reason: "Dangling image (no tag, no container)"
    metadata:
      image_id: "sha256:e3f4a8..."
      created_at: "2025-11-12T03:21:00Z"
      size_bytes: 184772819
```

## Field reference

### Top-level

| Field | Type | Required | Notes |
|---|---|---|---|
| `souji_plan_version` | integer | yes | Schema version. v1 = `1`. Apply rejects unknown versions with exit code 66. |
| `souji_version` | string | yes | `Souji::VERSION` at plan-generation time. Informational; not used for compatibility decisions. |
| `generated_at` | string | yes | RFC 3339 timestamp with offset. |
| `scenario` | mapping | yes | See below. |
| `target_roots` | sequence of strings | yes | Normalized absolute paths. Apply uses these for scope containment checks (FR-019). |
| `items` | sequence of mappings | yes | May be empty (no candidates). |

### `scenario` sub-mapping

| Field | Type | Required | Notes |
|---|---|---|---|
| `path` | string | yes | Absolute path to the scenario file at plan time. Informational only — apply does not read it (FR-011a). |
| `content_sha256` | string | yes | Hex-encoded SHA-256 of the scenario file bytes at plan time. Informational only (FR-011a). |

### `items[i]` mapping

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | Format: `"<recipe>:<ULID>"`. ULID is Crockford base32, 26 chars. Unique within the plan. |
| `recipe` | string | yes | Registered recipe name. Apply rejects items whose recipe is unknown at apply time. |
| `path` | string | yes | Absolute filesystem path OR a recipe-specific synthetic URI (e.g., `docker-image://<id>`). For filesystem paths, MUST be under one of `target_roots`. |
| `reason` | string | yes | Human-readable, ≤ 200 characters. |
| `size_bytes` | integer | no | Only a figure the recipe believes will **actually be freed on this host**. Omit when the recipe cannot say; see the reserved metadata keys below. |
| `metadata` | mapping | no | Recipe-defined extra fields. Apply passes the whole item (including `metadata`) to `Recipe#verify` and `Recipe#delete`. |

## Encoding rules

- File MUST be UTF-8.
- File MUST be valid YAML 1.2 parseable by Ruby `Psych`.
- Strings containing characters that YAML would interpret (`:`, `#`, leading
  whitespace) MUST be quoted. Souji's writer always single-quotes paths to
  avoid ambiguity.
- Mappings preserve insertion order (Souji always emits the top-level keys in
  the order shown above for readability).

## Compatibility policy

- Adding a new optional top-level field, or an optional sub-field of `scenario`
  or `items[i]`, is a **non-breaking change** and does NOT bump
  `souji_plan_version`.
- Adding a new required field, removing/renaming a field, changing a field's
  type, or changing the meaning of an existing field IS a **breaking change**
  and DOES bump `souji_plan_version`. New Souji versions MUST be able to read
  the previous major version OR fail with a clear migration message.
- `metadata` inside an item is recipe-private with the exception of the
  reserved keys below. Recipes may freely change the rest of their metadata
  schema between Souji versions; the framework never inspects it.

## Reserved metadata keys

`metadata` is recipe-private, except for these keys, which the framework does
read. A recipe that sets one is making a claim the framework acts on.

| Key | Type | Read by | Meaning |
|---|---|---|---|
| `size_bytes_upper_bound` | integer | `Plan#summary`, the apply prompt | Only meaningful when `size_bytes` is omitted: the most this item could possibly free. Reported as upside, never summed into the total. |
| `size_basis` | string | humans reading the plan | How the figure was obtained, so the number is self-documenting. |
| `host_space_unaffected` | boolean | `Plan#summary`, the apply prompt | The bytes are freed somewhere the host's `df` will not show — inside a docker VM's disk image. Excluded from the host total and reported on their own line. |
| `irreversible` | boolean | humans reading the plan | Deletion does not go through the trash and cannot be undone. |
| `scope_free` | boolean | humans reading the plan | The item is not under any `target_root`; see `recipe-interface.md`. |
| `argv` | sequence of strings | the recipe's own `#delete` | The literal command the deletion will run, so the plan reads as a reviewable script. |
| `command` | string | the recipe's own `#verify` | The executable whose presence on PATH is re-checked. |
| `cache_dir` | string | the recipe's own `#verify` | The directory whose existence is re-checked. |

## Validation rules (applied at apply-time load)

1. `souji_plan_version` is a known version (currently only `1`).
2. `target_roots` is non-empty.
3. Every `items[i].id` is unique within the plan.
4. Every `items[i].recipe` resolves to a registered recipe at apply time
   (recipes shipped by the running Souji version).
5. For every filesystem-backed item (path is absolute and not a `…://…` URI),
   `path` MUST be under at least one `target_root` after symlink resolution.
   Violations abort apply with exit code 66.

Failure of any of (1)–(5) is a plan error — exit code 66, no deletions performed.

## Reference fixtures

- [`examples/plan-example.yaml`](./examples/plan-example.yaml) — fully populated
  plan covering all three v1 recipes (`git-worktree`, `terraform-provider`,
  `docker-image`), including filesystem-backed and synthetic-URI items.
- [`examples/plan-empty-example.yaml`](./examples/plan-empty-example.yaml) —
  zero-item plan for the "nothing to clean up" path.

Both fixtures are also intended as inputs for the implementation-phase
parse / round-trip tests in `spec/unit/plan_spec.rb`.
