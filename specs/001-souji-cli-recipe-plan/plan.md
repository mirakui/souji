# Implementation Plan: Souji CLI — Recipe-based Plan & Apply

**Branch**: `001-souji-cli-recipe-plan` | **Date**: 2026-05-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-souji-cli-recipe-plan/spec.md`

## Summary

Souji is a Ruby CLI tool that crawls developer-workstation directories and identifies
"unneeded" artifacts (abandoned git worktrees, unreferenced terraform provider caches,
dangling docker image layers) for cleanup. Users write Souji scenarios in a trusted
Ruby DSL that composes named recipes. Cleanup runs in two phases: `souji plan` produces
a human-readable YAML plan file (read-only); `souji apply` consumes that plan and
performs the deletions with explicit confirmation, per-item recipe re-verification, and
a structured action log.

This plan targets a single Ruby gem with a thin CLI front-end over a library core
(per Constitution Principle I). Built-in recipes for v1 are `git-worktree`,
`terraform-provider`, and `docker-image`. Test discipline follows t_wada-style TDD with
RSpec (Constitution Principle III, NON-NEGOTIABLE).

## Technical Context

**Language/Version**: Ruby >= 3.2 (uses `Data.define` for value objects; widely available
on developer workstations via rbenv/asdf/system Ruby on recent macOS / Linux distros).

**Primary Dependencies**:
- `thor` (~> 1.3) — CLI subcommand dispatch (`souji plan`, `souji apply`).
- `psych` (stdlib) — YAML emission and parsing for plan files.
- `fileutils` (stdlib) — filesystem traversal and deletion helpers.
- No runtime dependency on `git`, `terraform`, or `docker` libraries; recipes shell out
  and parse text output.
- Dev/test only: `rspec` (~> 3.13), `rubocop` (~> 1.x, lint), `simplecov` (coverage).

**Storage**: Local filesystem only. Plan files are YAML on disk. Action logs are stdout
+ optional JSON Lines file. No database, no network, no remote state.

**Testing**: RSpec. Unit tests in `spec/unit/`, integration tests in `spec/integration/`
that exercise real `git` / `docker` / `terraform` subprocesses against scratch fixtures.
Coverage target: 80%+ (per project CLAUDE.md rule).

**Target Platform**: macOS (>=13) and Linux (any glibc-based distro from the last 3
years). Windows is out of scope per spec Assumptions.

**Project Type**: Single-project CLI tool packaged as a Ruby gem (`exe/souji` +
`lib/souji/`).

**Performance Goals**: `souji plan` for a typical developer workstation (one `~/work`
tree with 10–50 git repos containing 0–5 worktrees each, plus a workstation-wide
terraform provider cache and docker image set) MUST complete in under 30 seconds wall
clock. `souji apply` for a plan containing ≤ 1,000 items MUST complete in under 60
seconds wall clock excluding external-command time. These are workstation-grade
targets, not server SLAs.

**Constraints**:
- `plan` MUST be read-only against the filesystem under target roots
  (Constitution V; spec FR-008, SC-003).
- Default execution MUST NOT require sudo, root, or any privileged capability.
- No telemetry or outbound network calls in any code path (privacy / offline use).
- The tool MUST refuse to operate on paths outside scenario-declared target roots
  (spec FR-019, SC-005).
- Default deletions of plain files/directories MUST prefer trash mechanisms; recipes
  whose resources are intrinsically non-trashable (docker image layers) MUST document
  and emit non-reversibility in apply-time output (Constitution V; spec Assumptions).
- Default file locations follow the XDG Base Directory Specification (spec FR-007a /
  FR-007b / FR-017a): scenarios resolve under `$XDG_CONFIG_HOME/souji/scenario/`,
  plan files under `$XDG_CACHE_HOME/souji/`, and apply action logs under
  `$XDG_STATE_HOME/souji/log/` (additive — stderr is always written too). Souji
  creates the cache and state subdirectories on demand but never auto-creates the
  config directory.

**Scale/Scope**: v1 ships 3 built-in recipes. Scenarios are expected to fit in one
hand-edited file; an upper bound of ~50 recipe invocations per scenario is well within
the design envelope. Plan files of up to ~10,000 items should remain readable and
parseable (typical real-world plans will be 1-2 orders of magnitude smaller).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Derived gates from `.specify/memory/constitution.md` v1.0.0:

| # | Principle | Gate (this feature) | Status |
|---|-----------|---------------------|--------|
| I | Library-First | Core cleanup engine lives in `lib/souji/` as an importable Ruby library. CLI (`exe/souji`, `lib/souji/cli.rb`) is a thin wrapper that does no work the library can't do. Library is independently usable from `irb`, other scripts, or tests. | PASS — planned layout enforces this; library exposes `Souji::Scenario`, `Souji::Plan`, `Souji::Apply`, `Souji::Recipes.registry` without requiring the CLI module. |
| II | CLI Interface | Every command obeys text-in / text-out: arguments + stdin → stdout (human-readable by default), diagnostics → stderr, exit code distinguishes success / expected failure / unexpected failure. Machine-readable JSON output is selectable via `--json` flag on appropriate subcommands. | PASS — see `contracts/cli-commands.md` (Phase 1). |
| III | Test-First (NON-NEGOTIABLE) | RSpec is in place from task 1. Every functional requirement (FR-001..FR-020) MUST have a failing test before implementation code is written. PRs that lack the failing-then-passing test in history are rejected per Constitution. | PASS — `/speckit-tasks` will emit explicit "write failing test for FR-X" tasks before each implementation task. |
| IV | Integration Testing | Recipe behavior, plan/apply round-trips, and external-tool detection are covered by integration tests that hit real `git`, real `docker`, real `terraform` (when available) against scratch directories in `spec/tmp/`. Mocks are restricted to the cases where the external tool is structurally unavailable in CI. | PASS — design accommodates this; CI matrix tags integration tests so they can be skipped on machines lacking a tool, with the tagged-skip surfacing in test output. |
| V | Safety by Default | (a) `plan` is structurally read-only — there is no filesystem-mutating code path reachable from the plan subcommand. (b) `apply` requires interactive confirmation; non-interactive operation requires explicit `--yes`. (c) `apply --dry-run` exists and bypasses confirmation only because it does nothing. (d) Per-item recipe re-verification (FR-015) gates every actual deletion. (e) Deletions outside the plan's enumerated items are structurally impossible (FR-016). (f) Trash-preferred for filesystem deletions where the platform supports it. | PASS — spec FR-008/FR-013/FR-014/FR-015/FR-016/FR-019 + design choices below collectively realize this. |

**Cross-cutting gates from Quality Gates & Operational Standards**:

- **Test gate**: TDD history MUST be preserved per task — handled by `/speckit-tasks`.
- **Linter / formatter gate**: `rubocop` configured with project rules; CI runs `bundle exec rubocop`.
- **Build gate**: `gem build souji.gemspec` MUST succeed from a fresh checkout.
- **Safety review**: PRs touching `lib/souji/apply.rb`, `lib/souji/trash.rb`, or any
  `lib/souji/recipes/*.rb` deletion path MUST be explicitly reviewed against
  Principle V (PR template will include a checkbox).
- **Observability**: `apply` MUST emit a structured action log per FR-017; design
  uses JSON Lines so the log is machine-parseable and append-safe.

**Result**: All gates pass with no violations. **Complexity Tracking is empty.**

## Project Structure

### Documentation (this feature)

```text
specs/001-souji-cli-recipe-plan/
├── plan.md                       # This file (/speckit-plan command output)
├── spec.md                       # Feature spec (already created)
├── research.md                   # Phase 0 output (this command)
├── data-model.md                 # Phase 1 output (this command)
├── quickstart.md                 # Phase 1 output (this command)
├── contracts/                    # Phase 1 output (this command)
│   ├── cli-commands.md           # CLI synopses, flags, exit codes
│   ├── plan-yaml-schema.md       # YAML schema for plan files
│   ├── recipe-interface.md       # Ruby Recipe base-class contract
│   ├── scenario-dsl.md           # User-facing DSL methods
│   └── action-log-schema.md      # JSON Lines action log schema
├── checklists/
│   └── requirements.md           # Spec quality checklist
└── tasks.md                      # Phase 2 output (/speckit-tasks — not created yet)
```

### Source Code (repository root)

```text
exe/
└── souji                         # bin entry point; requires "souji/cli" and invokes Souji::CLI.start

lib/
├── souji.rb                      # Top-level requires; exposes public constants (VERSION, Errors)
└── souji/
    ├── version.rb                # Souji::VERSION
    ├── cli.rb                    # Souji::CLI (Thor subclass) — `plan`, `apply` subcommands
    ├── commands/
    │   ├── plan_command.rb       # Souji::Commands::PlanCommand — orchestrates plan generation
    │   └── apply_command.rb      # Souji::Commands::ApplyCommand — orchestrates apply
    ├── scenario.rb               # Souji::Scenario — loads + evaluates the Ruby DSL file
    ├── dsl.rb                    # Souji::DSL — the context object that hosts DSL methods (recipe, target, ...)
    ├── plan.rb                   # Souji::Plan — Plan value object + YAML (de)serialization
    ├── plan_item.rb              # Souji::PlanItem — single deletion candidate
    ├── action_log.rb             # Souji::ActionLog — JSONL-format append-only log (stderr + XDG_STATE_HOME file)
    ├── confirmation.rb           # Souji::Confirmation — interactive y/N prompt; honors --yes / --dry-run
    ├── trash.rb                  # Souji::Trash — cross-platform safe-delete helper (macOS `trash` / Linux `gio trash`)
    ├── paths.rb                  # Souji::Paths — XDG name resolution (bare-name vs path-shape, FR-007a / FR-007b)
    ├── recipe.rb                 # Souji::Recipe — abstract base + registry
    ├── recipes.rb                # Souji::Recipes — registry / autoload glue for built-ins
    └── recipes/
        ├── git_worktree.rb       # Souji::Recipes::GitWorktree
        ├── terraform_provider.rb # Souji::Recipes::TerraformProvider
        └── docker_image.rb       # Souji::Recipes::DockerImage

spec/
├── spec_helper.rb                # RSpec config, coverage hooks, tmp-dir helpers
├── support/
│   ├── tmp_dir.rb                # scratch-directory fixture builder
│   ├── git_repo_factory.rb       # builds real git repos with worktrees for integration
│   └── docker_helper.rb          # detects docker availability; tags-skip otherwise
├── unit/
│   ├── plan_spec.rb              # YAML serialization round-trip
│   ├── plan_item_spec.rb
│   ├── scenario_spec.rb          # DSL evaluation, error handling
│   ├── recipe_registry_spec.rb
│   ├── confirmation_spec.rb
│   ├── paths_spec.rb             # XDG resolution, bare-name vs path-shape, env-var overrides
│   └── trash_spec.rb
└── integration/
    ├── cli_plan_spec.rb          # end-to-end `souji plan` against fixtures
    ├── cli_apply_spec.rb         # end-to-end `souji apply` lifecycle
    ├── recipes/
    │   ├── git_worktree_spec.rb  # real git subprocesses
    │   ├── terraform_provider_spec.rb
    │   └── docker_image_spec.rb  # tagged :docker; skips when docker absent
    └── safety_spec.rb            # FR-008 read-only invariant, FR-016 plan containment

souji.gemspec                     # Gem metadata + runtime/dev deps
Gemfile                           # Bundler entry; bundle install for dev
Rakefile                          # rake spec / rake rubocop tasks
.rubocop.yml                      # project lint config
.rspec                            # RSpec default options
README.md                         # User-facing docs (out of scope for v1 spec; written in implement phase)
```

**Structure Decision**: Single-project Ruby gem (Option 1 from the plan template). The
gem layout `exe/` + `lib/<name>/` + `spec/` is the idiomatic Ruby community standard
and directly enforces Constitution Principle I (library-first): the CLI binary
(`exe/souji`) is a 3-line shim, all logic lives in importable classes under `lib/souji/`.
Integration tests run real subprocesses against scratch directories rather than mocking
the boundaries — this realizes Principle IV.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No violations. Constitution Check passes on all five principles. No table entries.
