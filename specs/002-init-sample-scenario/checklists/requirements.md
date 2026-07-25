# Specification Quality Checklist: `souji init` — Generate a Sample Scenario

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-05-22
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- The spec reuses terminology and conventions established by parent spec
  `001-souji-cli-recipe-plan` (XDG paths, bare-name resolution, exit codes,
  built-in recipes). Where it touches an existing rule, it cites the parent FR
  number (e.g., parent FR-007b on the scenario directory being user-provisioned).
- Five Clarifications session items recorded under `## Clarifications > Session
  2026-05-22` in `spec.md`, resolving the remaining open decisions:
  1. Default bare name → `default` (was `sample`).
  2. Sample recipe scope → `git-worktree` only; the other built-ins appear
     commented-out with enable instructions.
  3. `<name>` validation → strict ASCII allowlist
     `^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$` (FR-004).
  4. Non-regular destination → always rejected, `--force` does not override
     (FR-005a).
  5. Atomic write via temp file + `rename(2)` is required (FR-011, SC-006).
- Three of those items were revised at implementation time; see `## Clarifications
  > Session 2026-07-25 (implementation)` in `spec.md`. Items 1, 4 and 5 shipped as
  specified. Item 2 was superseded (the template is entirely commented out, so no
  recipe is active), item 3 was deferred along with the `<name>` argument itself,
  and the "existing regular file" case became a no-op success instead of exit 2.
- Items marked incomplete require spec updates before `/speckit-plan`.
