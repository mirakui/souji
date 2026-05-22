---

description: "Task list for Souji CLI — Recipe-based Plan & Apply"
---

# Tasks: Souji CLI — Recipe-based Plan & Apply

**Input**: Design documents from `/Users/naruta/src/souji/specs/001-souji-cli-recipe-plan/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests are MANDATORY** for this feature. Constitution v1.0.0 Principle III
(Test-First — NON-NEGOTIABLE) requires that every implementation task be
preceded by a failing test task that expresses the intended behavior. This
overrides the `.specify/templates/tasks-template.md` default that treats
tests as optional. Each user story phase below interleaves "Tests for User
Story N" before "Implementation for User Story N".

**Organization**: Tasks are grouped by user story to enable independent
implementation and testing of each story. Setup and foundational tasks come
first; the three user stories from spec.md (US1 = `souji plan`, US2 =
`souji apply`, US3 = scenario composition in Ruby DSL) follow in priority
order.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Setup, Foundational, and Polish tasks have NO story label.

## Path Conventions

- **Single project Ruby gem**: `exe/souji` + `lib/souji/` + `spec/` at repository root (per plan.md).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Initialize the Ruby gem skeleton, build/lint/test tooling, and the
trivial entry points required before any code can exercise Souji.

- [X] T001 Create directory structure at repo root: `exe/`, `lib/souji/commands/`, `lib/souji/recipes/`, `spec/support/`, `spec/unit/recipes/`, `spec/integration/recipes/`, `spec/tmp/` (gitignored)
- [X] T002 [P] Create `souji.gemspec` declaring name="souji", version reference, `required_ruby_version = ">= 3.2"`, runtime dep `thor ~> 1.3`, dev deps `rspec ~> 3.13`, `rubocop ~> 1`, `simplecov`
- [X] T003 [P] Create `Gemfile` with `gemspec` and `source "https://rubygems.org"`
- [X] T004 [P] Create `Rakefile` exposing `rake spec` (RSpec::Core::RakeTask) and `rake rubocop` (RuboCop::RakeTask), default task = `:spec`
- [X] T005 [P] Create `.rubocop.yml` with project rules (target Ruby 3.2, `Style/Documentation` disabled for now)
- [X] T006 [P] Create `.rspec` with `--color --require spec_helper --format documentation`
- [X] T007 [P] Create `spec/spec_helper.rb` wiring SimpleCov, autoloading `spec/support/**/*.rb`, declaring `:git` / `:docker` / `:terraform` tag-based skip filters
- [X] T008 [P] Create `exe/souji` (3-line shim: shebang, `require "souji/cli"`, `Souji::CLI.start(ARGV)`); chmod +x
- [X] T009 [P] Create `lib/souji.rb` top-level requires (version, errors, paths, plan_item, plan, recipe, recipes)
- [X] T010 [P] Create `lib/souji/version.rb` declaring `Souji::VERSION = "0.1.0"`
- [X] T011 [P] Create `.gitignore` for `*.gem`, `coverage/`, `.bundle/`, `Gemfile.lock` (lib-style gem), `spec/tmp/`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Library primitives that every user story depends on: XDG path
resolution, value objects (`PlanItem`, `Plan`), the `Recipe` registry, and
test fixture builders. Each implementation task is preceded by a failing
unit spec per Constitution III.

**CRITICAL**: No user story work begins until this phase is complete.

### Souji::Paths (FR-007a / FR-007b — XDG bare-name vs path-shape resolution)

- [X] T012 [P] Write failing spec for `Souji::Paths` in `spec/unit/paths_spec.rb` covering: path-shape detection (`/`, `~`, `.rb`, `.soujiplan`), bare-name lookup under `$XDG_CONFIG_HOME/souji/scenario/` (scenarios) and `$XDG_CACHE_HOME/souji/` (plans), `$XDG_STATE_HOME/souji/log/` resolution, default fallbacks (`~/.config`, `~/.cache`, `~/.local/state`) when env vars unset, missing-file error message listing the tried path
- [X] T013 Implement `Souji::Paths` module in `lib/souji/paths.rb` to pass T012 (no behavior beyond what tests require)

### Souji::PlanItem (data-model.md — immutable value object)

- [X] T014 [P] Write failing spec for `Souji::PlanItem` in `spec/unit/plan_item_spec.rb` covering: `Data.define` equality + hash, `id` format validation `<recipe-name>:<ULID>`, frozen instances, deep `metadata` access
- [X] T015 Implement `Souji::PlanItem` in `lib/souji/plan_item.rb` using `Data.define`

### Souji::Plan (contracts/plan-yaml-schema.md — YAML round-trip + validation)

- [X] T016 [P] Write failing spec for `Souji::Plan` in `spec/unit/plan_spec.rb` covering: `load_yaml` of `contracts/examples/plan-example.yaml` and `plan-empty-example.yaml`, round-trip `dump_yaml → load_yaml` byte-equality after timestamp normalization, `souji_plan_version` mismatch raises `Souji::IncompatiblePlanError`, scope-containment check rejects items outside `target_roots` with `Souji::ScopeViolationError`, `#summary` per-recipe counts
- [X] T017 Implement `Souji::Plan` in `lib/souji/plan.rb` and the error classes in `lib/souji/errors.rb` (define `Souji::Error`, `Souji::IncompatiblePlanError`, `Souji::ScopeViolationError`, `Souji::UnknownRecipeError`, `Souji::DuplicateRecipeError`)

### Souji::Recipe base class + registry (contracts/recipe-interface.md)

- [X] T018 [P] Write failing spec for `Souji::Recipe` in `spec/unit/recipe_registry_spec.rb` covering: `recipe_name` setter + validation (`/\A[a-z][a-z0-9-]*\z/`), `required_external_commands`, `description`, `inherited` hook registers subclass into `Souji::Recipe.registry`, duplicate `recipe_name` raises `Souji::DuplicateRecipeError`, class-level `available?(cmd)` probe via `command -v`
- [X] T019 Implement `Souji::Recipe` abstract base class in `lib/souji/recipe.rb`
- [X] T020 Implement `Souji::Recipes` module in `lib/souji/recipes.rb` providing autoload entries for the three built-in recipes (the recipe classes themselves come later, but the autoload glue lands here so `Souji::Recipe.registry` is populated on `require "souji"`)

### Test support helpers

- [X] T021 [P] Create `spec/support/tmp_dir.rb` providing an RSpec helper `with_tmp_dir { |path| ... }` that creates a scratch dir under `spec/tmp/` and trashes it after the example
- [X] T022 [P] Create `spec/support/git_repo_factory.rb` providing helpers to build a real git repo and attached worktrees (active + prunable) for integration specs
- [X] T023 [P] Create `spec/support/docker_helper.rb` that detects `docker` availability and exposes a `requires_docker!` helper that calls `skip` when the binary is missing (paired with the `:docker` tag filter in spec_helper)

**Checkpoint Phase 2**: Foundation ready — user story phases may now run in parallel.

---

## Phase 3: User Story 1 — `souji plan` (P1) 🎯 MVP

**Goal**: A user can run `souji plan <scenario>` and obtain a human-readable
YAML plan file enumerating every deletion candidate. The filesystem under
target roots is unchanged. This is the entire safety story.

**Independent Test**: Given `contracts/examples/scenario-weekly.rb` (placed
at `~/.config/souji/scenario/weekly.rb`) and a scratch `~/work` containing one
active worktree and two prunable worktrees, `souji plan weekly` writes
`~/.cache/souji/weekly.soujiplan` listing exactly the two prunable worktrees
with their paths and the `git-worktree` recipe attribution; the worktree
directories on disk are byte-identical before and after.

### Tests for User Story 1 — Write these FIRST (must FAIL before any impl)

- [X] T024 [P] [US1] Write failing spec for `Souji::DSL::Context` in `spec/unit/dsl_spec.rb` covering: `target` accumulation (relative paths resolved against scenario dir), `recipe` invocation recording with name + targets + params, `with_targets` block scoping, scope-escalation rejection (per-recipe `targets:` outside scenario `target` set), evaluation under `instance_eval`
- [X] T025 [P] [US1] Write failing spec for `Souji::Scenario` in `spec/unit/scenario_spec.rb` covering: `from_file` happy path, `content_sha256` computation, error path when scenario file missing (exit 2 message), unknown-recipe handling routed to `Souji::UnknownRecipeError`, target normalization (symlink resolution), uses `contracts/examples/scenario-weekly.rb`, `scenario-personal.rb`, `scenario-anti-unknown-recipe.rb`, `scenario-anti-scope-escape.rb` as fixtures
- [X] T026 [P] [US1] Write failing integration spec for `Souji::Recipes::GitWorktree#enumerate` in `spec/integration/recipes/git_worktree_spec.rb` tagged `:git`, using `git_repo_factory`: builds 1 active + 2 prunable worktrees, asserts `enumerate` returns exactly the 2 prunable worktrees as `PlanItem`s with deterministic ordering, asserts the worktree directories are unchanged before/after (FR-008)
- [X] T027 [P] [US1] Write failing integration spec for `Souji::Recipes::TerraformProvider#enumerate` in `spec/integration/recipes/terraform_provider_spec.rb` tagged `:terraform`: fixture builds a `.terraform.lock.hcl` referencing `aws 4.55.0` plus a plugin-cache containing `aws/4.50.0`, `aws/4.55.0`, `random/3.4.0`; asserts `enumerate` flags `aws/4.50.0` and `random/3.4.0` and NOT `aws/4.55.0`
- [X] T028 [P] [US1] Write failing integration spec for `Souji::Recipes::DockerImage#enumerate` in `spec/integration/recipes/docker_image_spec.rb` tagged `:docker`: uses `requires_docker!`, tags a temporary image then untags it to create a dangling image, asserts `enumerate` returns a `PlanItem` for that image
- [X] T029 [P] [US1] Write failing integration spec for the recipe contract (shared examples) in `spec/integration/recipe_contract_spec.rb`: every registered recipe MUST return deterministic enumeration for the same fixture, MUST return `:ok` from `verify` for items it just enumerated, MUST refuse to enumerate paths outside `target_roots`
- [X] T030 [P] [US1] Write failing integration spec for `Souji::Commands::PlanCommand` in `spec/integration/cli_plan_spec.rb`: end-to-end `souji plan weekly` against fixtures, asserts exit 0 + plan file written to `~/.cache/souji/weekly.soujiplan` (with `XDG_CACHE_HOME` redirected via env); unknown recipe → exit 65; missing scenario → exit 2 with tried path on stderr; external command missing → recipe skipped with `[souji] recipe '<name>' skipped: command '<cmd>' not found` on stderr, plan still produced for remaining recipes (FR-020); bare-name resolves through `Souji::Paths`; explicit `-o` overrides default output
- [X] T031 [P] [US1] Write failing integration spec for read-only invariant in `spec/integration/safety_spec.rb`: SHA-256 of every file under target roots is byte-identical before and after `souji plan` across 100% of plan runs (FR-008, SC-003)

### Implementation for User Story 1

- [X] T032 [P] [US1] Implement `Souji::DSL::Context` in `lib/souji/dsl.rb` (`target`, `recipe`, `with_targets`; records `RecipeInvocation` objects; raises on scope escalation)
- [X] T033 [US1] Implement `Souji::Scenario` in `lib/souji/scenario.rb`: `from_file(path)` reads + `instance_eval(source, path, 1)`; computes `content_sha256`; provides `#run_plan(registry)` that probes each recipe's `required_external_commands` (per-recipe skip with stderr warning per FR-020), invokes `enumerate`, aggregates `PlanItem`s into a `Souji::Plan`. Depends on T020 (registry) and T032 (DSL).
- [X] T034 [P] [US1] Implement `Souji::Recipes::GitWorktree#enumerate` in `lib/souji/recipes/git_worktree.rb`: declares `recipe_name "git-worktree"` + `required_external_commands "git"`; shells `git -C <target> worktree list --porcelain` per git directory under target roots; flags entries marked `prunable`; returns deterministic-ordered `PlanItem`s
- [X] T035 [P] [US1] Implement `Souji::Recipes::TerraformProvider#enumerate` in `lib/souji/recipes/terraform_provider.rb`: declares `recipe_name "terraform-provider"`, no external command (pure fs + line-based `.terraform.lock.hcl` parsing); scans target roots for `.terraform.lock.hcl`, builds referenced `{namespace, provider, version}` set, flags unreferenced cache entries under `~/.terraform.d/plugin-cache/` (or `TF_PLUGIN_CACHE_DIR` if set)
- [X] T036 [P] [US1] Implement `Souji::Recipes::DockerImage#enumerate` in `lib/souji/recipes/docker_image.rb`: declares `recipe_name "docker-image"` + `required_external_commands "docker"`; shells `docker images --digests --format '{{json .}}'`; flags dangling images (`<none>:<none>`); returns `PlanItem` with synthetic `docker-image://<digest>` path and `metadata.irreversible: true`
- [X] T037 [US1] Implement `Souji::Commands::PlanCommand` in `lib/souji/commands/plan_command.rb`: orchestrates `Souji::Scenario.from_file → #run_plan → Souji::Plan.dump_yaml`; handles `-o`/`--output` (default via `Souji::Paths` per FR-007b), `--target-root` (repeatable), `--log-file`, `--quiet`; prints one-line summary on stdout; maps domain errors to exit codes (0 / 1 / 2 / 65). Depends on T033 + T034 + T035 + T036.
- [X] T038 [US1] Implement `Souji::CLI` Thor subclass in `lib/souji/cli.rb` with `plan` subcommand wired to `Souji::Commands::PlanCommand`; handle `souji --version` / `souji version`. Depends on T037.

**Checkpoint US1**: `souji plan weekly` works end-to-end against the example
scenarios; plan files match the schema in `contracts/plan-yaml-schema.md`;
read-only invariant holds; external-command absence is non-fatal.

---

## Phase 4: User Story 2 — `souji apply` (P2)

**Goal**: A user can run `souji apply <plan>` against a plan produced in
US1, get a confirmation prompt summarizing the deletion set, and have the
items removed with per-item recipe re-verification, structured action log
to stderr AND `$XDG_STATE_HOME/souji/log/`, and a final exit code that
reflects success vs partial failure.

**Independent Test**: Given the plan produced by the US1 acceptance test,
running `souji apply weekly` with `y` confirmation removes exactly the two
prunable worktree directories, leaves the active worktree untouched, writes
a JSONL action log to `~/.local/state/souji/log/<timestamp>-weekly.jsonl`,
and exits 0.

### Tests for User Story 2 — Write these FIRST

- [ ] T039 [P] [US2] Write failing spec for `Souji::Confirmation` in `spec/unit/confirmation_spec.rb`: interactive `y/N` (case-insensitive `y` → `:proceed`); `--yes` short-circuits to `:proceed`; non-TTY without `--yes` returns `:cancel` with exit 130 hint
- [ ] T040 [P] [US2] Write failing spec for `Souji::Trash` in `spec/unit/trash_spec.rb`: platform detection order (`trash` → `osascript` → `gio trash` → freedesktop fs fallback → hard-delete + loud warning); each branch yields the expected outcome symbol (`:trashed` vs `:deleted`); shell-injection safety via `Shellwords.escape`
- [ ] T041 [P] [US2] Write failing spec for `Souji::ActionLog` in `spec/unit/action_log_spec.rb`: per-item JSONL emission (fields per `contracts/action-log-schema.md`); terminal `summary: true` line; default file destination `$XDG_STATE_HOME/souji/log/<UTC-ts>-<basename>.jsonl` resolved via `Souji::Paths`; `--log-file <path>` override; `--no-log-file` suppresses file; `--log-file` + `--no-log-file` is exit 2 (usage error); log-dir unwritable → fallback to stderr-only + one-line stderr warning; stderr emission unaffected in all cases
- [ ] T042 [P] [US2] Extend `spec/integration/recipes/git_worktree_spec.rb` with `verify` (re-checks `git worktree list --porcelain` and returns `:ok` / `[:skip, reason]`) and `delete` (shells `git worktree remove --force <path>`, returns `:deleted`); covers re-activated worktree → skipped
- [ ] T043 [P] [US2] Extend `spec/integration/recipes/terraform_provider_spec.rb` with `verify` (re-scan lockfiles confirms still unreferenced) and `delete` (via `Souji::Trash`, returns `:trashed`); covers newly-referenced provider → skipped
- [ ] T044 [P] [US2] Extend `spec/integration/recipes/docker_image_spec.rb` with `verify` (re-query `docker images` for the digest) and `delete` (`docker image rm <id>`, returns `:deleted` not `:trashed` per `metadata.irreversible: true`); covers image-now-tagged → skipped
- [ ] T045 [P] [US2] Write failing integration spec for `Souji::Commands::ApplyCommand` in `spec/integration/cli_apply_spec.rb`: load plan from XDG cache + path-shape; scope-check before prompt (FR-016, exit 66); confirmation prompt + `--yes`; `--dry-run` bypasses prompt and skips all `Recipe#delete` calls (FR-014); per-item verify → delete flow; action log written to `$XDG_STATE_HOME` file + stderr; exit code matrix: 0 all-ok, 73 partial failure, 130 cancellation, 66 bad plan, 2 conflicting flags
- [ ] T046 [P] [US2] Add scope-containment refusal case to `spec/integration/safety_spec.rb`: hand-edit plan to add a path outside target_roots; `souji apply` MUST exit 66 with stderr message identifying the offending path, MUST NOT call any `Recipe#delete` (FR-016, SC-005)
- [ ] T047 [P] [US2] Add edge-case integration cases to `spec/integration/cli_apply_spec.rb`: "scenario edited after plan" (apply ignores scenario file changes per FR-011a), "external command unavailable at apply time" (per-item verify returns skip with reason, apply continues, exit 0)

### Implementation for User Story 2

- [ ] T048 [P] [US2] Implement `Souji::Confirmation` in `lib/souji/confirmation.rb`
- [ ] T049 [P] [US2] Implement `Souji::Trash` in `lib/souji/trash.rb` (platform probe chain + `Shellwords` escaping + hard-delete fallback emitting stderr warning)
- [ ] T050 [P] [US2] Implement `Souji::ActionLog` in `lib/souji/action_log.rb` (stderr writer + best-effort file writer; depends on `Souji::Paths`)
- [ ] T051 [US2] Extend `Souji::Recipes::GitWorktree` in `lib/souji/recipes/git_worktree.rb` with `verify` + `delete` (uses `git worktree remove --force`)
- [ ] T052 [US2] Extend `Souji::Recipes::TerraformProvider` in `lib/souji/recipes/terraform_provider.rb` with `verify` + `delete` (uses `Souji::Trash`)
- [ ] T053 [US2] Extend `Souji::Recipes::DockerImage` in `lib/souji/recipes/docker_image.rb` with `verify` + `delete` (shells `docker image rm <id>`; returns `:deleted`)
- [ ] T054 [US2] Implement `Souji::Commands::ApplyCommand` in `lib/souji/commands/apply_command.rb`: load + scope-check plan; bulk confirmation; per-item verify → delete with `ActionLog` events; exit code mapping (0 / 1 / 2 / 66 / 73 / 130). Depends on T048 + T049 + T050 + T051 + T052 + T053.
- [ ] T055 [US2] Wire `apply` subcommand into `Souji::CLI` in `lib/souji/cli.rb` (options: `--yes`, `--dry-run`, `--log-file <path>`, `--no-log-file`; mutual-exclusion validation between the last two)

**Checkpoint US2**: `souji apply weekly` executes the full lifecycle:
prompt → verify → delete → log. Audit trail lands in `$XDG_STATE_HOME/souji/log/`.

---

## Phase 5: User Story 3 — Author scenarios in Ruby DSL (P3)

**Goal**: Users compose multi-recipe scenarios with `with_targets` blocks,
pass recipe-specific parameters, and freely mix DSL with Ruby helpers
(`Dir.glob`, constants, conditionals). Anti-pattern scenarios fail with
exit 65 before they can cause damage.

**Independent Test**: Plan against `contracts/examples/scenario-personal.rb`
yields candidates from all three recipes with `with_targets`-scoped terraform
results; plan against `scenario-multi-repo.rb` correctly enumerates per-repo
worktrees discovered via `Dir.glob`; both anti-pattern fixtures fail with
exit 65 and stderr messages identifying the issue.

Most DSL surface is implemented in US1 (T032). US3 verifies it under the
intended user-facing scenarios and adds recipe-specific parameter support
exercised end-to-end.

### Tests for User Story 3 — Write these FIRST

- [ ] T056 [P] [US3] Extend `spec/unit/dsl_spec.rb` with parameter-passing cases: `recipe "docker-image", older_than_days: 30` reaches `Recipe#enumerate`'s `params` hash with `{older_than_days: 30}`; unknown keyword args are accepted (recipes own their param schema)
- [ ] T057 [P] [US3] Add integration test in `spec/integration/cli_plan_spec.rb` for `contracts/examples/scenario-personal.rb`: asserts `with_targets` constrains terraform-provider to `~/work/infra` and `~/playground/tf` only; asserts `docker-image` receives `older_than_days: 30`
- [ ] T058 [P] [US3] Add integration test in `spec/integration/cli_plan_spec.rb` for `contracts/examples/scenario-multi-repo.rb`: `Dir.glob` in scenario enumerates targets correctly; produced plan contains per-repo worktrees
- [ ] T059 [P] [US3] Add anti-pattern integration tests in `spec/integration/cli_plan_spec.rb` for `contracts/examples/scenario-anti-unknown-recipe.rb` (exit 65, stderr names the unknown recipe + available recipes) and `scenario-anti-scope-escape.rb` (exit 65, stderr identifies the offending `recipe` call)

### Implementation for User Story 3

- [ ] T060 [US3] If T032 doesn't already pass keyword args through to `RecipeInvocation#params`, fix `Souji::DSL::Context#recipe` in `lib/souji/dsl.rb` so `**params` reaches `Recipe#enumerate`
- [ ] T061 [US3] Implement `older_than_days:` parameter handling in `Souji::Recipes::DockerImage` in `lib/souji/recipes/docker_image.rb` (filter `enumerate` results by image `created_at`); illustrates the recipe-specific param pattern for future recipes

**Checkpoint US3**: All three example scenarios behave as documented; both
anti-pattern fixtures fail safely.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Ship-readiness. Coverage gate, lint cleanup, CI, performance
smoke test, packaging, and user-facing docs.

- [ ] T062 [P] Write `README.md` at repo root: install, link to `specs/001-souji-cli-recipe-plan/quickstart.md`, list of v1 recipes with one-line descriptions, badges placeholder
- [ ] T063 [P] Add `souji help recipes` subcommand in `lib/souji/cli.rb` that prints the registered recipes + their `description` declarations
- [ ] T064 [P] Add `.github/workflows/ci.yml` running `bundle exec rspec` (excluding `:docker` tag for default matrix; include `:docker` on a separate job that boots dockerd) and `bundle exec rubocop` on Ruby 3.2 + 3.3
- [ ] T065 [P] Performance smoke test in `spec/integration/perf_spec.rb`: synthetic `~/work` with 50 git repos × ~2 worktrees each; assert `souji plan` completes in under 30s (matches plan.md Performance Goals)
- [ ] T066 [P] Enforce 80% coverage via `SimpleCov.minimum_coverage 80` in `spec/spec_helper.rb` and resolve any gaps revealed by `rake spec`
- [ ] T067 [P] Resolve all rubocop warnings introduced during implementation; `bundle exec rubocop` exits 0
- [ ] T068 Build the gem: `gem build souji.gemspec` succeeds and produces `souji-0.1.0.gem`; verify `gem install ./souji-0.1.0.gem && souji version` prints `souji 0.1.0`
- [ ] T069 Reconcile `specs/001-souji-cli-recipe-plan/quickstart.md` with any user-visible behavior that drifted during implementation; update the spec checklists entry under "Notes" if so

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately.
- **Foundational (Phase 2)**: depends on Setup completion. BLOCKS all user stories.
- **User Stories (Phase 3+)**: depend on Foundational. After Phase 2, US1 / US2 / US3 can in principle proceed in parallel, but in practice:
  - US2 implementation depends on `Souji::Plan` round-trip (T017) which is in Phase 2 — fine.
  - US2 extends each recipe with `verify` + `delete` on top of US1's `enumerate` implementations (T034-T036) — those US1 impls are prerequisites.
  - US3 mostly verifies DSL behavior implemented in US1 (T032) and adds a recipe param example to docker-image — needs T032 and T036 done.
- **Polish (Phase 6)**: depends on all desired user stories being complete (US1 + US2 + US3 for v1).

### Within Each User Story

- **TDD ordering (NON-NEGOTIABLE)**: every "Tests for User Story N" task must be written and FAIL before its paired implementation task runs.
- Models / value objects before services.
- Services before commands.
- Commands before CLI wiring.

### Story-Level Dependencies (visualized)

```text
Setup (Phase 1)
  └─► Foundational (Phase 2: Paths, PlanItem, Plan, Recipe registry, helpers)
        ├─► US1 (Phase 3: DSL, Scenario, recipes#enumerate, PlanCommand, CLI plan)
        │     └─► US3 (Phase 5: recipe params, anti-pattern + multi-target plan tests)
        ├─► US2 (Phase 4: Confirmation, Trash, ActionLog, recipes#verify+#delete, ApplyCommand, CLI apply)
        │     └─► (depends on US1 recipes' enumerate impls existing — T034..T036)
        └─► Polish (Phase 6: docs, CI, perf, coverage, gem build) — after US1+US2+US3
```

### Parallel Opportunities

- All Setup tasks marked `[P]` (T002–T011) run in parallel; T001 first to create the directory tree.
- All Phase 2 "spec" tasks marked `[P]` (T012, T014, T016, T018, T021–T023) run in parallel; their paired "impl" tasks (T013, T015, T017, T019, T020) run sequentially per unit but in parallel across units.
- US1 tests (T024–T031) all parallel; US1 impls T032 / T034 / T035 / T036 parallel (different recipe files / DSL); T033 sequential after T020+T032; T037 sequential after T033+T034+T035+T036; T038 sequential after T037.
- US2 tests (T039–T047) parallel; impls T048 / T049 / T050 parallel; recipe extensions T051 / T052 / T053 parallel (different recipe files); T054 after all three plus T048+T049+T050; T055 after T054.
- US3 tests (T056–T059) parallel; impls T060 + T061 parallel.
- Polish (T062–T067) all parallel; T068 + T069 sequentially at the end.

---

## Parallel Example: User Story 1

```bash
# After T020 + T023 finish, launch every US1 test in parallel:
Task: "Write failing spec for Souji::DSL::Context in spec/unit/dsl_spec.rb"            # T024
Task: "Write failing spec for Souji::Scenario in spec/unit/scenario_spec.rb"           # T025
Task: "Write failing integration spec for GitWorktree#enumerate"                       # T026
Task: "Write failing integration spec for TerraformProvider#enumerate"                 # T027
Task: "Write failing integration spec for DockerImage#enumerate"                       # T028
Task: "Write failing integration spec for recipe contract shared examples"             # T029
Task: "Write failing integration spec for PlanCommand end-to-end"                      # T030
Task: "Write failing integration spec for plan read-only invariant"                    # T031

# After T024 + T025 fail as expected, parallel implementations:
Task: "Implement Souji::DSL::Context in lib/souji/dsl.rb"                              # T032
Task: "Implement Souji::Recipes::GitWorktree#enumerate in lib/souji/recipes/git_worktree.rb"     # T034
Task: "Implement Souji::Recipes::TerraformProvider#enumerate in lib/souji/recipes/terraform_provider.rb"  # T035
Task: "Implement Souji::Recipes::DockerImage#enumerate in lib/souji/recipes/docker_image.rb"     # T036
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (Paths, PlanItem, Plan, Recipe registry, test helpers).
3. Complete Phase 3: User Story 1 (souji plan end-to-end with three built-in recipes' `enumerate`).
4. **STOP and VALIDATE**: run `souji plan weekly` against `contracts/examples/scenario-weekly.rb`; confirm a plan file is produced, no filesystem mutations occur under target roots, the plan matches `contracts/plan-yaml-schema.md`.
5. Demo-ready: at this point `souji plan` has standalone value (developers can see what would be cleaned without any apply mechanism).

### Incremental Delivery

1. **MVP** = Setup + Foundational + US1 → `souji plan` works.
2. **+US2** → `souji apply` works (full plan/apply cycle).
3. **+US3** → scenarios scale to real-world cleanup policies.
4. **+Polish** → ship to RubyGems.

Each increment validates Constitution V (Safety by Default) — destructive
power is only added in US2, on top of the structurally read-only plan
phase.

### Parallel Team Strategy

With three developers after Phase 2 lands:

- Developer A → US1 (plan flow + recipe enumerates).
- Developer B → US2 (apply flow + recipe verify/delete). Has to coordinate with A on the recipe class shape since both stories extend the same `Souji::Recipes::*` files; A lands `enumerate` first, B layers in `verify` + `delete`.
- Developer C → US3 (DSL verification + docker `older_than_days` param). Mostly waits for A's DSL impl (T032) and docker impl (T036).

---

## Notes

- `[P]` tasks operate on different files and have no incomplete dependencies.
- `[Story]` labels map every story-phase task to a user story for traceability.
- Each user story is independently completable and testable; US1 is the MVP.
- Tests are MANDATORY here, not optional — Constitution III overrides the template default. Verify each test FAILS for the stated reason before writing the matching implementation.
- Commit after each task or logical group (Conventional Commits per CLAUDE.md global rules).
- Stop at any checkpoint to validate a story independently before proceeding.
- Avoid vague tasks, same-file conflicts within a [P] batch, and cross-story dependencies that break independence beyond what the dependency graph above documents.
