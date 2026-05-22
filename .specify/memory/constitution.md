<!--
Sync Impact Report
==================
Version change: (uninitialized template) → 1.0.0
Bump rationale: Initial ratification — template placeholders replaced with concrete
project governance; MAJOR baseline established for a brand-new constitution.

Modified principles:
- [PRINCIPLE_1_NAME] → I. Library-First
- [PRINCIPLE_2_NAME] → II. CLI Interface
- [PRINCIPLE_3_NAME] → III. Test-First (NON-NEGOTIABLE)
- [PRINCIPLE_4_NAME] → IV. Integration Testing
- [PRINCIPLE_5_NAME] → V. Safety by Default

Added sections:
- Core Principles (5 principles, fully defined)
- Quality Gates & Operational Standards (was [SECTION_2_NAME])
- Development Workflow (was [SECTION_3_NAME])
- Governance (fully defined)

Removed sections:
- None (all template placeholder sections were populated, none discarded).

Templates requiring updates:
- ✅ .specify/memory/constitution.md (this file)
- ⚠ .specify/templates/plan-template.md — "Constitution Check" section is a stub.
   Future amendment may want to enumerate concrete gates derived from principles
   I–V (library-first justification, CLI/text I-O, test-first proof, integration
   test coverage, dry-run/safety review). Not blocking; intentionally deferred to
   keep templates pristine for this initial ratification.
- ⚠ .specify/templates/spec-template.md — currently treats tests as discretionary;
   Principle III makes them non-negotiable. Future amendment may want to add a
   "Test Strategy" mandatory section. Deferred for the same reason as plan-template.
- ⚠ .specify/templates/tasks-template.md — states "Tests are OPTIONAL".
   This conflicts with Principle III for any feature governed by this
   constitution. Documented here so the next /speckit-tasks invocation can
   override the default and require failing tests before implementation tasks.

Follow-up TODOs:
- None. RATIFICATION_DATE established as 2026-05-22 per user direction.
-->

# Souji Constitution

## Core Principles

### I. Library-First

Every user-facing feature MUST be implemented as a standalone, importable library before
any CLI, daemon, or integration layer is added. Libraries MUST be self-contained,
independently testable, and documented with a clear single-purpose mission. Organizational-
only or "utility grab-bag" libraries are prohibited — every library MUST justify its
existence by a concrete capability that a caller can invoke in isolation.

**Rationale**: Library-first design forces decoupling, keeps the public surface explicit,
and makes the same logic reusable from automation, tests, and alternate front-ends without
duplication.

### II. CLI Interface

Every library MUST expose its capabilities through a CLI surface. The CLI MUST follow a
text-in / text-out protocol: arguments and stdin for input, stdout for results, stderr for
diagnostics, and an exit code that distinguishes success, expected failure, and unexpected
error. Both human-readable and machine-readable (JSON) output MUST be supported, selectable
via a stable flag.

**Rationale**: Text protocols make every feature scriptable, composable with Unix
pipelines, and trivially testable by recording stdin/stdout pairs. JSON output preserves
machine consumption without sacrificing terminal ergonomics.

### III. Test-First (NON-NEGOTIABLE)

Test-Driven Development in the t_wada style is mandatory for every change. The required
loop is: write a failing test that expresses the intended behavior → confirm it fails for
the stated reason → implement the minimum code to make it pass → refactor with the test as
a safety net. Implementation code MUST NOT be authored before a failing test exists.
Pull requests that introduce production code without a paired failing-then-passing test
in history MUST be rejected.

**Rationale**: Tests written after implementation tend to encode the implementation rather
than the intent, and skip the falsification step that distinguishes a real test from a
tautology. Writing them first is the only reliable way to guarantee the contract is met
and regressions are caught.

### IV. Integration Testing

Integration tests are REQUIRED for: new library public contracts, any change to an
existing public contract, inter-process or inter-service communication, and any data or
schema shared across module boundaries. Integration tests MUST exercise the real
boundary (real filesystem, real subprocess, real serialization) rather than mocked
substitutes wherever the boundary is the thing under test. Mocks are permitted only for
external dependencies that are out of scope for the test or genuinely unreachable in CI.

**Rationale**: Unit tests prove a function works in isolation; integration tests prove
the seams hold. For a tool that mutates user state, the seams are where damage happens,
so they MUST be tested against the real thing.

### V. Safety by Default

Any operation that mutates, removes, or otherwise cannot be trivially undone MUST default
to a non-destructive mode. Concretely: (a) destructive commands MUST provide a dry-run
or preview flag and SHOULD make it the default; (b) deletion MUST prefer reversible
mechanisms (e.g., trash / quarantine) over irrecoverable removal where the platform
allows; (c) any irreversible action MUST require explicit user confirmation or an
explicit opt-in flag, and MUST never be triggered by a default invocation; (d) the tool
MUST refuse to operate on paths or resources it cannot validate as in-scope.

**Rationale**: Souji exists to clean things up — a category of work where mistakes
destroy user data and trust. Safe defaults make the worst-case outcome of a misused
command "nothing happened" rather than "files are gone".

## Quality Gates & Operational Standards

The following gates apply to every change before it may be merged:

- **Test gate**: Failing-test-first history MUST be preserved or attested in the PR. All
  tests (unit + integration) MUST pass on the target branch's CI configuration.
- **Linter / formatter gate**: Project linters and formatters MUST pass with zero errors.
  Warnings introduced by the change MUST be either resolved or explicitly justified in
  the PR description.
- **Build gate**: The build artifact (CLI binary, library bundle, or equivalent) MUST be
  produced cleanly from a fresh checkout.
- **Safety review**: Any change that touches a destructive code path MUST be reviewed
  against Principle V — dry-run path, confirmation prompt, and scope validation MUST be
  explicitly verified by the reviewer.
- **Observability**: Destructive operations MUST emit a structured record (machine-
  readable line on stderr or a log file) of what was acted on, sufficient to reconstruct
  the change after the fact.

## Development Workflow

- **Branching**: Feature work MUST occur on a feature branch created via the
  `/speckit-git-feature` workflow. Direct commits to `main` are reserved for the
  governance artifacts in `.specify/` and equivalent metadata.
- **Spec-driven**: Non-trivial features MUST flow through the Spec Kit pipeline:
  `/speckit-specify` → `/speckit-clarify` (when ambiguous) → `/speckit-plan` →
  `/speckit-tasks` → `/speckit-implement`. The constitution check in the plan phase
  MUST be passed (or any violation justified in the Complexity Tracking table) before
  task generation.
- **Commits**: Commit messages MUST follow Conventional Commits. The body SHOULD record
  the prompt or directive that motivated the change when the author used an AI assistant,
  so the historical record is reproducible.
- **Reviews**: Every PR MUST be reviewed against the principles above. Reviewers MUST
  explicitly cite which principles apply when requesting changes, so the rule being
  enforced is visible to the author and to future readers.
- **Scratch space**: Throwaway debugging and verification scripts MUST live under
  `.cctmp/scratch/` and MUST NOT be committed to the repository.

## Governance

This constitution supersedes any conflicting practice, convention, or ad-hoc rule
elsewhere in the project. Where a project document (README, CLAUDE.md, template) appears
to contradict the constitution, the constitution wins until that document is updated.

**Amendment procedure**: Amendments are proposed by opening a PR that modifies this file
and any dependent templates in the same change set. The PR MUST include: (a) the
motivation for the change, (b) the proposed version bump and its justification per the
versioning policy below, and (c) a migration plan for any in-flight features that the
amendment would affect.

**Versioning policy**: This constitution follows semantic versioning.
- **MAJOR**: A principle is removed, a principle's meaning is changed in a backward-
  incompatible way, or governance is restructured such that prior PRs would no longer
  pass review under the new rules.
- **MINOR**: A new principle or governance section is added, or an existing principle is
  materially expanded with new MUST/SHOULD obligations.
- **PATCH**: Wording clarifications, typo fixes, rationale rewrites, or other non-
  semantic refinements that do not change what passes or fails review.

**Compliance review**: PR reviewers MUST verify compliance with the principles and gates
above on every PR. Any deliberate violation MUST be recorded in the PR's Complexity
Tracking (or equivalent) section with the justification and the simpler alternative that
was rejected. Use `CLAUDE.md` and the per-feature plan / spec artifacts for runtime
development guidance; this constitution is the source of truth for what those artifacts
must enforce.

**Version**: 1.0.0 | **Ratified**: 2026-05-22 | **Last Amended**: 2026-05-22
