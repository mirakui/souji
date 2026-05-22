# Specification Quality Checklist: Souji CLI — Recipe-based Plan & Apply

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

- The spec mentions "Ruby DSL" and "YAML" because both are user-facing surfaces:
  the user authors scenarios in Ruby, and plan files are read by humans as YAML.
  These are properties of the user-visible contract, not internal implementation
  details, consistent with the spec-template guidance for CLI tools.
- "Ruby" as the implementation language is recorded in Assumptions only (per user
  direction), not in functional requirements.
- No [NEEDS CLARIFICATION] markers — reasonable defaults were chosen per the
  spec-template guidance and documented in Assumptions.
- `/speckit-clarify` session 2026-05-22 resolved three high-impact ambiguities
  (DSL evaluation model, apply/scenario decoupling, external-command absence)
  and they are recorded in spec.md under the `## Clarifications` section, with
  matching updates in FR-005a, FR-011, FR-011a, FR-020, and Edge Cases.
- 2026-05-22 follow-up: scenario / plan file locations standardized on XDG
  Base Directory (`$XDG_CONFIG_HOME/souji/scenario/`, `$XDG_CACHE_HOME/souji/`).
  Recorded in spec.md Clarifications and in new FR-007a / FR-007b; propagated
  to contracts/cli-commands.md, contracts/scenario-dsl.md, quickstart.md,
  research.md (R12), and plan.md (Souji::Paths module).
- 2026-05-22 follow-up: action log default destination moved to
  `$XDG_STATE_HOME/souji/log/<UTC-timestamp>-<plan-basename>.jsonl` (additive
  to stderr) for an automatic audit trail aligned with Constitution V. New
  FR-017a / FR-017b in spec.md plus an Edge Case for unwritable log dir;
  contracts/cli-commands.md and contracts/action-log-schema.md updated;
  research.md gains R13.
- Items marked incomplete would require spec updates before `/speckit-plan`.
