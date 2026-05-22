# Recipe Interface Contract

**Feature**: 001-souji-cli-recipe-plan
**Date**: 2026-05-22

This contract defines the Ruby interface every recipe MUST implement. It is the
internal extensibility surface invoked by `Souji::Scenario#run_plan` (at plan
time) and `Souji::Commands::ApplyCommand` (at apply time).

The contract is internal in the sense that v1 does not publish a third-party
plugin mechanism (spec Assumptions). New built-in recipes inside the gem rely
on this contract.

## Base class

```ruby
module Souji
  class Recipe
    # Class-level DSL — every concrete recipe declares these in its class body.
    def self.recipe_name(name = nil); end       # required, sets identifier
    def self.required_external_commands(*cmds); end  # optional, default []
    def self.description(text = nil); end       # optional, used by `souji help recipes`

    # Lifecycle methods — concrete recipes override these.
    def enumerate(target_roots, params); end    # required
    def verify(plan_item); end                  # required
    def delete(plan_item); end                  # required
  end
end
```

## Class-level declarations

### `recipe_name(name)`

**Required**. Sets the registry key. Format: `/\A[a-z][a-z0-9-]*\z/`.

```ruby
class Souji::Recipes::GitWorktree < Souji::Recipe
  recipe_name "git-worktree"
end
```

### `required_external_commands(*cmds)`

**Optional**. Lists shell commands the recipe depends on. The framework probes
each via `command -v` at plan time; if any is missing, the recipe is skipped
with a stderr warning (FR-020).

```ruby
required_external_commands "git"
```

### `description(text)`

**Optional**. One-line description shown in `souji help recipes`.

## Instance methods (the lifecycle)

### `#enumerate(target_roots, params) -> Array<PlanItem>`

Called at plan time. Returns the deletion candidates this recipe identifies
under the given target roots.

**Inputs**:
- `target_roots` — array of normalized absolute paths. The recipe's
  invocation-scoped targets (subset of scenario `target_roots`).
- `params` — hash of recipe-specific keyword args from the DSL call.

**Output**: `Array<Souji::PlanItem>`. The recipe is responsible for
constructing items with stable IDs and accurate `reason` strings.

**Contract**:
- MUST NOT modify the filesystem under `target_roots` (FR-008, SC-003).
- MUST NOT enumerate paths outside `target_roots` (FR-019). The framework
  defends this at item-construction time, but recipes should not generate
  out-of-scope candidates in the first place.
- MUST be deterministic for a given input (FR-006, SC-004): same target roots
  + same filesystem state ⇒ same item list in the same order.
- MAY read external state (run `git`, read `terraform` cache files, query
  `docker`) but MUST treat that state as read-only.

### `#verify(plan_item) -> :ok | [:skip, reason]`

Called at apply time, just before `#delete`, for every plan item.

**Inputs**:
- `plan_item` — the `Souji::PlanItem` from the plan file.

**Outputs**:
- `:ok` — proceed to `#delete`.
- `[:skip, reason]` where `reason` is a short human-readable string — the item
  no longer qualifies (was already deleted, was modified, is now in use, etc.).
  Apply records this as outcome `skipped` in the action log and moves on.

**Contract**:
- MUST NOT mutate the filesystem.
- MUST be cheap enough to call once per plan item without dominating apply
  runtime.
- MAY return `:skip` even for "still exists but no longer qualifies" — e.g., a
  worktree that has been re-attached, a terraform provider version that has
  been freshly referenced.

### `#delete(plan_item) -> :deleted | :trashed | [:failed, error]`

Called at apply time after a successful `#verify`.

**Outputs**:
- `:deleted` — the item was removed irreversibly (e.g., docker image, git
  worktree via `git worktree remove`).
- `:trashed` — the item was moved to the platform trash (via `Souji::Trash`)
  and could in principle be restored manually.
- `[:failed, error]` where `error` is a `StandardError` — apply records the
  failure in the action log and exits with code 73 at the end of the run.

**Contract**:
- MAY shell out, MAY use `Souji::Trash`, MAY use any recipe-specific deletion
  mechanism.
- MUST NOT delete anything other than the resource described by `plan_item`.
- For filesystem-backed items, MUST re-check scope containment immediately
  before deletion (defense in depth — the framework checks at plan-load and at
  scope-validation, but the recipe is closest to the actual `unlink`).

## Recipe lifecycle summary

```text
Class load
  │
  ▼
Souji::Recipe.inherited hook  ──►  registers subclass in Souji::Recipe.registry
                                   keyed by recipe_name

Plan time (souji plan)
  │
  ▼
Souji::Scenario#run_plan
  │
  ▼ for each RecipeInvocation:
    probe required_external_commands  ─┐
                                       ├─► skipped if missing (FR-020)
    Recipe#enumerate                   ─┘
  │
  ▼ collect PlanItems
Souji::Plan dumped to YAML

Apply time (souji apply)
  │
  ▼ for each PlanItem:
    Recipe#verify  ──► :skip,reason   ─►  action log: skipped
                  ──► :ok
    Recipe#delete  ──► :deleted        ─►  action log: deleted
                  ──► :trashed         ─►  action log: trashed
                  ──► [:failed, err]   ─►  action log: failed, exit 73
```

## Reference: testing a recipe

Every recipe MUST have:

- A unit spec in `spec/unit/recipes/<name>_spec.rb` covering `recipe_name`,
  `required_external_commands`, and pure logic (e.g., `.lock.hcl` parsing).
- An integration spec in `spec/integration/recipes/<name>_spec.rb` that
  exercises `enumerate`, `verify`, `delete` against a real fixture. For recipes
  with external commands, the spec is tagged (`:git`, `:docker`, `:terraform`)
  so CI can skip when the tool is absent.

A recipe contract test (`spec/integration/recipe_contract_spec.rb`, shared
across all recipes via RSpec shared examples) verifies that each registered
recipe:

1. Returns deterministic enumeration for the same fixture.
2. Returns `:ok` from `verify` for items it just enumerated.
3. Survives a plan→apply round-trip on a scratch fixture.
4. Refuses to operate on a plan item whose path is outside scope.
