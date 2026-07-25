# Scenario DSL Contract

**Feature**: 001-souji-cli-recipe-plan
**Date**: 2026-05-22

This contract defines the user-facing Ruby DSL exposed by Souji scenario files.
It is the public surface users write against; changes here are breaking changes
to existing scenarios.

Per spec clarification Q1 (Trusted full Ruby), scenarios are evaluated via
`instance_eval` against a `Souji::DSL::Context`. Inside the scenario, all Ruby
language constructs (variables, control flow, `require`, helper methods) are
available; the DSL methods below are additional vocabulary that the context
exposes.

## Default scenario location

By convention, scenarios live under `$XDG_CONFIG_HOME/souji/scenario/`
(defaulting to `~/.config/souji/scenario/` when `$XDG_CONFIG_HOME` is unset).
A file at `~/.config/souji/scenario/weekly.rb` is invoked via
`souji plan weekly` — the bare-name lookup is described in spec FR-007a and
`contracts/cli-commands.md`. Scenarios in any other location work too: any
argument containing `/`, starting with `~`, or ending with `.rb` is treated
as a filesystem path.

Souji does NOT auto-create `~/.config/souji/scenario/`; that directory is the
user's to provision (typically once, at install time).

## DSL methods

### `target(path, *more_paths)`

Declares a target root. May be called multiple times; each call appends to the
scenario's target set. Paths may be absolute or relative; relative paths are
resolved against the scenario file's directory at evaluation time. Symlinks
are resolved.

```ruby
target "~/work"
target File.expand_path("~/playground")
```

A `target` set at the top level is the default scope for every `recipe` call
that does not pass its own `targets:` argument.

### `recipe(name, targets: nil, **params)`

Records a recipe invocation. Will be executed during `souji plan`.

**Arguments**:

- `name` (string, required) — the recipe name (e.g., `"git-worktree"`).
- `targets:` (array of strings or single string, optional) — override the
  default target set for just this invocation. Must be a subset of the
  scenario-level `target` declarations (no scope escalation; see FR-019).
- `**params` (optional) — recipe-specific keyword arguments. Each recipe
  declares the keys it accepts via `param` (see `recipe-interface.md`); passing
  an undeclared key is an error, not a silently ignored hash entry. Run
  `souji recipes` for the live list of each recipe's options.

```ruby
recipe "git-worktree"
recipe "terraform-provider", targets: ["~/work/infra"]
recipe "docker-image", older_than_days: 30
```

### `with_targets(*paths, &block)`

Sugar for scoping multiple `recipe` calls to a narrower set of targets:

```ruby
target "~/work"
target "~/playground"

with_targets "~/work/infra" do
  recipe "terraform-provider"
  recipe "git-worktree"
end
```

Equivalent to passing `targets:` to each `recipe` call inside the block.

`with_targets` narrows an existing scope, it does not create one: at least one
`target` must already be declared. A scenario that reaches for `with_targets`
(or `recipe(targets:)`) with nothing declared is rejected at evaluation time
rather than allowed to enumerate against a scope the plan would then have to
throw away wholesale.

## Evaluation semantics

- The scenario file is read into a string and evaluated with
  `instance_eval(source, scenario_path, 1)`. The filename and starting line
  are passed so syntax/runtime errors point at the user's file in their
  backtrace.
- The context is throwaway: it is constructed per `souji plan` invocation and
  discarded after the plan is built.
- The scenario is validated in full before any recipe enumerates: every recipe
  name is resolved against the registry and every param checked against the
  recipes' declarations, and all offenders are reported in one error. Walking a
  home directory takes seconds, so a scenario must never scan for that long
  only to die on a typo in its last line.
- Recipe invocations are executed in the order they are written in the file.
  This ordering is preserved in the generated plan's `items` (along with
  per-recipe internal ordering) so two `plan` runs against the same scenario +
  same filesystem state yield byte-identical plans (FR-006, SC-004).

## Error behavior

- Syntax errors in the scenario file → exit code 65, stderr line identifying the
  file and line.
- Unknown recipe name (recipe not in the registry) → exit code 65, stderr
  message naming the unknown recipe and the available recipe names.
- Targets that escape the scenario-level target set → exit code 65, stderr
  message identifying the violating `recipe` call.
- `with_targets` or `recipe(targets:)` used with no `target` declared → exit
  code 65, stderr message naming the `target` declaration to add.
- A param a recipe does not declare → exit code 65, stderr message naming the
  offending key and the keys that recipe does accept.

Every error above is raised before any recipe enumerates, so a rejected
scenario costs no filesystem traversal.

No exception classes are part of the DSL contract — users do not catch them in
scenario code.

## Example scenarios

### Minimal scenario

```ruby
# weekly.rb
target "~/work"
recipe "git-worktree"
recipe "docker-image"
```

### Multi-target with parameters

```ruby
# personal.rb
target File.expand_path("~/work")
target File.expand_path("~/playground")

# Only terraform under infra dirs
with_targets "~/work/infra", "~/playground/tf" do
  recipe "terraform-provider"
end

# Worktrees everywhere
recipe "git-worktree"

# Docker only for old layers
recipe "docker-image", older_than_days: 30
```

### Using helper code

Because scenarios are full Ruby, users can compute paths programmatically:

```ruby
%w[work playground oss].each do |dir|
  target File.expand_path("~/#{dir}")
end

recipe "git-worktree"
```

## Anti-patterns

The DSL is deliberately permissive (trusted Ruby), but the following are bad
ideas users should avoid:

- **Network calls in a scenario**: scenarios are evaluated every time `souji plan`
  runs. Doing HTTP fetches makes plans non-deterministic and slow.
- **Filesystem mutation in a scenario**: plan must be read-only (FR-008). The
  DSL does not stop you from calling `File.write` in a scenario, but it will
  violate the safety invariant and break the SC-003 measurable outcome.
- **`exit`, `abort`, or `at_exit` callbacks**: these will short-circuit Souji's
  own control flow. The DSL does not block them but their use is unsupported.

## Reference fixtures

Happy-path scenarios (parse & evaluate cleanly):

- [`examples/scenario-weekly.rb`](./examples/scenario-weekly.rb) — minimal
  scenario with one target and two recipes.
- [`examples/scenario-personal.rb`](./examples/scenario-personal.rb) —
  multi-target with `with_targets` block and a recipe-specific parameter.
- [`examples/scenario-multi-repo.rb`](./examples/scenario-multi-repo.rb) —
  programmatic target enumeration via `Dir.glob`.

Anti-pattern scenarios (must fail with exit code 65):

- [`examples/scenario-anti-unknown-recipe.rb`](./examples/scenario-anti-unknown-recipe.rb) —
  references a recipe that is not in the registry.
- [`examples/scenario-anti-scope-escape.rb`](./examples/scenario-anti-scope-escape.rb) —
  per-recipe `targets:` escapes the scenario-level target set.

Both anti-examples are intended as inputs for the negative-path tests in
`spec/unit/scenario_spec.rb`.
