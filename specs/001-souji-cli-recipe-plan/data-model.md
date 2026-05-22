# Phase 1 Data Model: Souji CLI

**Feature**: 001-souji-cli-recipe-plan
**Date**: 2026-05-22

The data model is small and entirely in-process / on-disk; there is no database.
All entities are Ruby value objects (using `Data.define` where natural) or thin
domain classes. Field names below match the YAML / Ruby surface; see
`contracts/plan-yaml-schema.md` for the on-disk schema.

## Entity: Recipe

**Description**: A named cleanup strategy. Abstract Ruby class; concrete subclasses
live in `lib/souji/recipes/`.

**Identity**: `recipe_name` (string, e.g. `"git-worktree"`). Unique across the
registry.

**Attributes**:

| Field | Type | Required | Notes |
|---|---|---|---|
| `recipe_name` | string | yes | DSL-facing identifier. Lowercase + dashes by convention. |
| `required_external_commands` | array&lt;string&gt; | no (default `[]`) | Executables the recipe shells out to; checked by FR-020 probe. |
| `description` | string | no | Human-readable one-liner shown in `souji help recipes`. |

**Behavior contract** (full method signatures in
`contracts/recipe-interface.md`):

- `#enumerate(target_roots, params) -> Array<PlanItem>` — read-only scan that
  returns deletion candidates. MUST NOT mutate the filesystem.
- `#verify(plan_item) -> :ok | [:skip, reason]` — called at apply time per
  candidate. Returns `:ok` if the item still qualifies, or `[:skip, reason]` if
  the situation has changed and the deletion should be skipped (FR-015).
- `#delete(plan_item) -> :deleted | [:failed, error]` — actually removes the
  resource. May shell out, may call `Souji::Trash`, may use a recipe-specific
  mechanism (e.g., `docker image rm`).

**Lifecycle**:

- Created once at process start via the autoload hook in `lib/souji/recipes.rb`.
- Registered into `Souji::Recipe.registry` keyed by `recipe_name`.
- One instance per recipe (recipes are stateless; concurrent invocations within
  a single souji run share an instance).

**Validation rules**:

- `recipe_name` MUST match `/\A[a-z][a-z0-9-]*\z/`. Enforced at registration.
- Duplicate `recipe_name` registrations MUST raise `Souji::DuplicateRecipeError`.

## Entity: Scenario

**Description**: A user-authored Ruby file evaluated as the source of truth for
which recipes to run and where.

**Identity**: Filesystem path. No global registry; scenarios are loaded ad-hoc
per invocation.

**Attributes** (after evaluation):

| Field | Type | Required | Notes |
|---|---|---|---|
| `path` | string | yes | Absolute path to the scenario file. |
| `content_sha256` | string | yes | SHA-256 of file bytes; informational metadata in plan (FR-011a). |
| `invocations` | array&lt;RecipeInvocation&gt; | yes | One per `recipe(...)` call in the DSL. Ordered as written. |
| `target_roots` | array&lt;string&gt; | yes | Absolute, normalized directories declared via `target(...)`. Recipes MUST NOT enumerate paths outside this set (FR-019). |

**Behavior contract**:

- `Souji::Scenario.from_file(path) -> Scenario`
- `#run_plan(recipes_registry) -> Plan` — invokes each recipe against its scoped
  targets, aggregates `PlanItem`s into a `Plan`. Read-only on the filesystem.

**Lifecycle**:

- Constructed at the start of `souji plan`; not persisted.
- Apply does NOT re-load the scenario (FR-011a).

**Validation rules**:

- `path` MUST exist and be readable when `from_file` is called.
- Each `RecipeInvocation`'s recipe name MUST be in the registry; unknown recipe
  raises `Souji::UnknownRecipeError` and aborts plan generation.
- `target_roots` MUST be non-empty for any recipe that requires a target (the
  DSL distinguishes target-required vs target-optional recipes via the recipe's
  declaration).
- Each path in `target_roots` MUST be normalized (absolute, symlinks resolved)
  to make scope-containment checks reliable.

## Entity: RecipeInvocation

**Description**: A single call to `recipe(...)` in the DSL. Intermediate
representation between scenario evaluation and plan execution.

**Attributes**:

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Recipe name as referenced in the DSL. |
| `targets` | array&lt;string&gt; | conditional | Targets scoped to this invocation (subset of scenario `target_roots`). Required for target-required recipes. |
| `params` | hash | no | Recipe-specific keyword args from the DSL call. |

**Validation rules**:

- `name` MUST resolve to a registered recipe.
- Every path in `targets` MUST be within `scenario.target_roots` (no scope
  escalation).

## Entity: Plan

**Description**: The deliverable of `souji plan`. Persisted as YAML.

**Identity**: Filesystem path of the YAML file. The plan also carries a generation
timestamp and Souji version for audit.

**Attributes**:

| Field | Type | Required | Notes |
|---|---|---|---|
| `souji_plan_version` | integer | yes | Schema version. v1 = `1`. |
| `souji_version` | string | yes | `Souji::VERSION` at plan time. |
| `generated_at` | string (RFC3339) | yes | Wall-clock time, ISO 8601 with offset. |
| `scenario.path` | string | yes | Path to the scenario file at plan time. |
| `scenario.content_sha256` | string | yes | Informational only (FR-011a). |
| `target_roots` | array&lt;string&gt; | yes | Normalized absolute paths. |
| `items` | array&lt;PlanItem&gt; | yes | Ordered list of deletion candidates. Order is deterministic per FR-006 / SC-004. |

**Behavior contract**:

- `Souji::Plan.dump_yaml(path)` — write to disk.
- `Souji::Plan.load_yaml(path) -> Plan` — read from disk and validate
  `souji_plan_version`.
- `#summary` — returns the breakdown printed at the top of `apply` (per-recipe
  counts + total size).

**Lifecycle**:

1. Built in memory by `Souji::Scenario#run_plan`.
2. Serialized to disk by `souji plan -o <path>`.
3. Consumed by `souji apply <path>`. Apply does NOT modify the plan file.

**Validation rules**:

- `souji_plan_version` MUST be a known version (v1 only supports `1`). Unknown
  versions raise `Souji::IncompatiblePlanError`.
- Every `PlanItem.path` MUST be within `target_roots` — defended at load time
  AND at delete time (FR-016, FR-019, SC-005).

## Entity: PlanItem

**Description**: A single deletion candidate.

**Attributes**:

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | Stable identifier scoped by recipe. Format: `"<recipe-name>:<ULID>"`. |
| `recipe` | string | yes | Recipe name that produced this item. |
| `path` | string | yes | Absolute path of the resource. For non-filesystem resources (docker images), a synthetic but stable identifier (e.g., `"docker-image://<image-id>"`) used purely for human readability and de-duplication. |
| `reason` | string | yes | Short human-readable justification. |
| `size_bytes` | integer | no | Best-effort size in bytes; omitted when not meaningful (docker layers). |
| `metadata` | hash | no | Recipe-specific extra fields (e.g., `{commit:, branch:}` for git-worktree). |

**Behavior contract**: PlanItem is an immutable `Data.define` value object. No
methods beyond accessors and `==` / `hash` (deep equality for de-duplication).

**Validation rules**:

- `id` MUST be unique within a single plan.
- `recipe` MUST refer to a registered recipe.
- For filesystem-backed items, `path` MUST be absolute and under one of the
  plan's `target_roots`.

## Entity: ActionLog

**Description**: Append-only record of what `apply` did, emitted as JSON Lines.

**Identity**: The log is process-scoped: stderr by default, optionally also tee'd
to a file.

**Attributes** (per log line):

| Field | Type | Required | Notes |
|---|---|---|---|
| `ts` | string (RFC3339) | yes | Timestamp of the action. |
| `item_id` | string | conditional | Required for per-item events; absent for the terminal summary. |
| `recipe` | string | conditional | Required for per-item events. |
| `path` | string | conditional | Required for per-item events. |
| `outcome` | string | yes | One of `deleted`, `trashed`, `skipped`, `failed`, plus `summary` for the terminal record. |
| `reason` | string | conditional | Required when `outcome == skipped`. |
| `error` | string | conditional | Required when `outcome == failed`. |
| `duration_ms` | integer | conditional | Required for per-item events and the summary. |

The terminal `summary` line carries counts: `deleted`, `trashed`, `skipped`,
`failed`, plus aggregated `duration_ms`.

**State transitions** (per plan item during apply):

```text
PlanItem
  │
  ▼ Recipe#verify
  ├── :ok ──► Recipe#delete ──► outcome: deleted | trashed | failed
  └── [:skip, reason] ──────────► outcome: skipped
```

`deleted` vs `trashed` distinguishes recipes that go through `Souji::Trash` from
recipes that perform native irreversible removal (e.g., docker).

## Entity: ConfirmationPrompt

**Description**: The interactive y/N gate that fronts every non-`--yes`
invocation of apply. Not persisted; in-memory only.

**Behavior contract**:

- `Souji::Confirmation.ask(plan, opts) -> :proceed | :cancel`
- Honors `--yes` (returns `:proceed` immediately).
- Honors `--dry-run` (returns `:proceed` but apply itself short-circuits before
  calling any `Recipe#delete`).
- On non-TTY without `--yes`, returns `:cancel` with exit code 130 — refuses to
  proceed silently against a pipe.

## Relationships

```text
Scenario 1 ──── *  RecipeInvocation  *  ──── 1 Recipe (by name)
   │
   │ produces (via run_plan)
   ▼
  Plan  1 ──── *  PlanItem  1 ──── 1 Recipe (by name)
   │
   │ consumed by
   ▼
 Apply ─── emits *  ActionLog  entries
```

Notes:
- `Scenario` and `Plan` are independent persistence boundaries. `Apply` consumes
  only `Plan` (per FR-011a).
- `Recipe` is referenced by name from both `RecipeInvocation` (DSL time) and
  `PlanItem` (apply time). The same registry resolves both, but the dependency
  on the scenario file ends at plan generation.

## Invariants (cross-entity)

- **Scope containment**: `∀ item ∈ plan.items, item.path ⊆ plan.target_roots`
  (FR-019, FR-016, SC-005).
- **Determinism**: `plan(scenario) == plan(scenario)` byte-for-byte after
  normalizing `generated_at` (FR-006, SC-004). Achieved by deterministic
  candidate ordering inside each recipe + stable recipe-invocation ordering from
  the DSL.
- **Read-only plan phase**: no code path reachable from `souji plan` calls
  `Recipe#delete` or `FileUtils.rm*` (FR-008, SC-003). Enforced at the type
  level — `Souji::Scenario#run_plan` never receives a "delete-capable"
  collaborator.
- **Plan-source-of-truth on apply**: `Souji::Commands::ApplyCommand` does not
  load the scenario file (FR-011a).
