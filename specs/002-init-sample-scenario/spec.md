# Feature Specification: `souji init` — Generate a Sample Scenario

**Feature Branch**: `002-init-sample-scenario`

**Created**: 2026-05-22

**Status**: Draft

**Input**: User description: "`souji init` でサンプルの scenario を生成するようにしたい"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - First-time user provisions a working scenario in one command (Priority: P1)

A developer has just installed Souji and read the quickstart. Instead of manually
running `mkdir -p ~/.config/souji/scenario` and pasting boilerplate Ruby into a
fresh file, they want a single command that gives them a runnable starter scenario
at the conventional XDG location, so the very next command they type can be
`souji plan <name>` and have it succeed.

The developer runs `souji init`. Souji creates `$XDG_CONFIG_HOME/souji/scenario/`
(including any missing parents) if it does not already exist, writes a sample
scenario file there with a sensible default name, and prints the resolved path on
stdout. The generated file is a syntactically valid scenario that loads cleanly
under `souji plan` and explains its own contents through inline comments.

**Why this priority**: This is the entire purpose of the `init` command. Without
it, the first-time-user onboarding sequence documented in `quickstart.md` requires
three manual steps (`mkdir`, `$EDITOR`, paste boilerplate) before Souji can do
anything useful. P1 because it is the smallest delta that converts a multi-step
manual setup into a single command and unblocks the entire quickstart flow.

**Independent Test**: From a workstation where `$XDG_CONFIG_HOME/souji/scenario/`
does not yet exist, running `souji init` produces a file under that directory and
exits with success. The file can be passed to `souji plan` without further editing
and `plan` parses it without raising a scenario error. Verifiable by running
`souji init && souji plan <generated-name>` in sequence and confirming a plan file
is produced.

**Acceptance Scenarios**:

1. **Given** a workstation where `$XDG_CONFIG_HOME/souji/scenario/` does not exist
   and no Souji config has ever been created, **When** the user runs `souji init`,
   **Then** the directory `$XDG_CONFIG_HOME/souji/scenario/` is created, a sample
   scenario file is written inside it, the command writes the absolute path of the
   generated file to stdout, and the command exits with success (exit code 0).
2. **Given** the file produced by `souji init` in scenario 1, **When** the user
   immediately runs `souji plan <generated-bare-name>`, **Then** Souji successfully
   resolves the bare name, evaluates the scenario without raising any scenario
   error, and produces a plan file at the default XDG cache location.
3. **Given** the file produced by `souji init`, **When** a human opens it in an
   editor, **Then** the file contains explanatory comments that name each DSL
   construct it uses (at minimum: `target` and `recipe`) so the reader can edit
   the file without consulting external documentation.

---

### User Story 2 - Re-running `init` does not silently clobber an edited scenario (Priority: P2)

A developer has already run `souji init` once, edited the generated scenario to
match their workstation (changed `target`, added/removed recipes), and is now
exploring `souji --help`. They accidentally invoke `souji init` a second time.
They want Souji to refuse to overwrite their customised file unless they explicitly
ask for it, so a stray keystroke cannot destroy their cleanup policy.

When the destination file already exists, `souji init` MUST refuse to overwrite it,
exit with a non-zero status, and print a stderr diagnostic that names the existing
path and tells the user how to force the overwrite. A `--force` flag MUST exist to
overwrite intentionally.

**Why this priority**: Destroying user-authored configuration on a re-invocation
would be a Principle V (Safety by Default) violation in spirit, mirroring how
`souji apply` requires explicit confirmation. P2 because the safety failure mode
is only reachable after US1 has been used at least once, but every user who keeps
their scenario over time will eventually hit this path.

**Independent Test**: Given a pre-existing scenario file at the destination,
running `souji init` exits non-zero and leaves the existing file byte-identical;
running `souji init --force` overwrites it. Verifiable by content-hash comparison
of the destination file before and after each invocation.

**Acceptance Scenarios**:

1. **Given** a file already exists at the destination scenario path, **When** the
   user runs `souji init` without `--force`, **Then** the command exits with a
   non-zero usage error status (exit code 2), stderr names the existing path and
   suggests `--force`, and the existing file's content is unchanged.
2. **Given** a file already exists at the destination scenario path with custom
   user edits, **When** the user runs `souji init --force`, **Then** the existing
   file is overwritten with the sample content, the command exits with success,
   and stdout names the path that was overwritten.

---

### User Story 3 - User chooses a custom name for the generated scenario (Priority: P3)

A developer wants more than one scenario over time (e.g., one for their personal
laptop, one for their work laptop) and does not want every `souji init` invocation
to fight over the same default filename. They want to control the bare name of the
generated file so they can run `souji init personal` and later `souji init work`
without `--force`.

`souji init` MUST accept an optional positional argument naming the scenario. The
generated file is written under the same XDG scenario directory as the default,
just with the user-supplied bare name. The name is then directly usable by `souji
plan <name>`.

**Why this priority**: A single hard-coded filename is enough to ship US1; the
ability to pick a name unlocks repeatable use across multiple machines and
projects. P3 because users can already work around this in v1 by renaming the file
after `init`, so this is a quality-of-life improvement rather than a blocker.

**Independent Test**: Running `souji init foo` writes a file whose basename
matches `foo.rb` under the XDG scenario directory and is resolvable by `souji plan
foo`. Verifiable by listing the directory and by running the plan command.

**Acceptance Scenarios**:

1. **Given** the user runs `souji init custom-name`, **When** the command
   completes, **Then** the generated file is located at
   `$XDG_CONFIG_HOME/souji/scenario/custom-name.rb` and `souji plan custom-name`
   resolves to that file.
2. **Given** the user supplies a name that already collides with an existing file
   in the scenario directory, **When** the user runs `souji init <existing-name>`,
   **Then** the same refuse-and-suggest-`--force` behaviour from US2 applies.

---

### Edge Cases

- **Scenario directory exists but is unwritable**: `$XDG_CONFIG_HOME/souji/scenario/`
  exists with read-only permissions, or the parent `$XDG_CONFIG_HOME` is on a
  read-only filesystem. `souji init` MUST exit with a non-zero status and stderr
  MUST name the unwritable path; no partial file is left on disk.
- **Bare name not a valid filename component**: The user passes an argument that
  contains a path separator, starts with `~`, or ends with `.rb` (the same
  predicates `Paths.path_shaped?` uses to identify filesystem paths). `souji init`
  MUST reject such inputs with a usage error (exit code 2), because the command
  is defined to write into the XDG scenario directory by bare name; users who want
  to write anywhere else are expected to use a normal editor.
- **Generated file references recipes that are not installed at apply time**: The
  sample MAY list recipes (e.g., `docker-image`) whose required external commands
  are not present on the current workstation. This is acceptable — running
  `souji plan` on the sample will simply skip those recipes with a stderr warning
  (existing behaviour per FR-020 of the parent spec). The sample SHOULD include a
  short comment pointing this out so a confused user understands why a recipe was
  skipped.
- **`$XDG_CONFIG_HOME` is set to a non-default location**: The destination path is
  derived from `$XDG_CONFIG_HOME` (with the documented fallback to `~/.config`),
  so a custom value MUST be honoured. Verified by running `XDG_CONFIG_HOME=/tmp/x
  souji init` and confirming the file lands under `/tmp/x/souji/scenario/`.
- **Re-running `souji init --force` against a file the user did not create with
  `init`**: There is no marker distinguishing a sample-generated scenario from a
  hand-authored one. `--force` MUST overwrite regardless of who wrote the file;
  the safety affordance is the absence of `--force`, not file-origin detection.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST expose an `init` subcommand of the `souji` CLI that,
  when invoked, generates a sample scenario file under
  `$XDG_CONFIG_HOME/souji/scenario/` (with the same XDG fallback to `~/.config`
  used by the rest of the CLI).
- **FR-002**: `souji init` MUST create the destination directory
  `$XDG_CONFIG_HOME/souji/scenario/` (and any missing parents) if it does not yet
  exist. This is the one and only command in Souji that is permitted to create
  this directory; the rest of the CLI MUST continue to honour FR-007b of the
  parent spec and treat the scenario directory as user-provisioned.
- **FR-003**: `souji init` MUST accept an optional positional `<name>` argument
  naming the bare scenario name to generate. When omitted, Souji MUST use a single
  documented default bare name (`sample`). The resolved filename MUST be
  `<name>.rb` under the scenario directory.
- **FR-004**: `souji init` MUST reject `<name>` arguments that would be treated as
  filesystem paths by the existing `Paths.path_shaped?` predicate (contain `/`,
  start with `~`, or end with `.rb`). On such input, Souji MUST exit with usage
  error (exit code 2) and stderr MUST explain that `<name>` must be a bare name.
- **FR-005**: When the destination file already exists, `souji init` MUST NOT
  overwrite it. Souji MUST exit with usage error (exit code 2) and stderr MUST
  include the existing path and the literal hint `--force` so the user knows how
  to override.
- **FR-006**: `souji init --force` MUST overwrite the destination file
  unconditionally (subject only to filesystem permissions), exit with success on
  successful overwrite, and report the overwritten path on stdout.
- **FR-007**: The generated file MUST be a syntactically valid scenario that loads
  cleanly under the existing scenario loader (`Souji::Scenario.from_file`). It
  MUST reference at least one `target` and at least one `recipe`, and every
  recipe it references MUST be a built-in recipe shipped with Souji
  (`git-worktree`, `terraform-provider`, or `docker-image`). The exact recipe
  combination is an implementation detail of the template, but it MUST be a
  non-empty subset of the built-ins so the file is immediately runnable.
- **FR-008**: The generated file MUST contain Ruby comments that name each DSL
  construct it uses (at minimum `target` and `recipe`) and a one-line note about
  recipes being skipped when their external command is missing, so a reader new
  to Souji can edit the file without consulting external documentation.
- **FR-009**: On success, `souji init` MUST print the absolute path of the
  generated (or overwritten) file to stdout and exit with success (exit code 0).
  On any failure (existing file without `--force`, invalid `<name>`, unwritable
  destination), Souji MUST exit with a non-zero status and write a diagnostic on
  stderr that names the problematic path.
- **FR-010**: `souji init` MUST NOT modify any file or directory other than the
  destination scenario file and the scenario directory itself. In particular it
  MUST NOT touch `$XDG_CACHE_HOME/souji/`, `$XDG_STATE_HOME/souji/log/`, or any
  user file outside the scenario directory.

### Key Entities

- **Sample scenario template**: The Ruby source text that `souji init` writes to
  disk. Ships as part of the Souji distribution. Contains placeholder `target`
  and `recipe` calls plus explanatory comments. Bytewise identical across all
  invocations of the same Souji version, so two `souji init --force` runs back to
  back produce identical files.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A first-time user can go from a fresh machine to a generated plan
  in exactly two commands (`souji init && souji plan sample`), with no manual
  directory creation, file editing, or copy-paste from documentation.
- **SC-002**: The file produced by `souji init` is accepted by `souji plan`
  without any scenario error in 100% of CI runs, on every supported platform
  (macOS and Linux), against an empty target directory.
- **SC-003**: Running `souji init` twice in a row (without `--force` on the
  second invocation) leaves the destination file byte-identical to its state
  after the first invocation. Verified by SHA-256 comparison before and after the
  second call.
- **SC-004**: Running `souji init --force` against a user-edited destination
  reproduces the same byte content as a fresh `souji init` against an empty
  directory; the user's prior edits are fully replaced.
- **SC-005**: A reader unfamiliar with Souji can, in under 2 minutes after
  opening the generated file, correctly state which directory will be scanned and
  which recipes will run, using only the comments in the file (no external
  documentation).

## Assumptions

- The `souji` CLI process has filesystem permission to create
  `$XDG_CONFIG_HOME/souji/scenario/` and to write a regular file inside it. Cases
  where this is false (read-only filesystem, restrictive `umask`, SELinux/macOS
  TCC denial) are reported as errors per FR-009; no privilege escalation,
  retry-with-sudo, or alternate-location fallback is in scope.
- The default bare name chosen for `souji init` when `<name>` is omitted is
  `sample`. This is a deliberate departure from the `weekly.rb` example in
  `quickstart.md` because `sample` more accurately signals to a first-time user
  that the generated file is a starting template, not a finished policy. The
  quickstart will be updated alongside this feature so the two stay in sync.
- The generated sample references only the three v1 built-in recipes
  (`git-worktree`, `terraform-provider`, `docker-image`) and a single `target`
  pointing at `~/work`, mirroring the example in `quickstart.md` for continuity.
  The exact recipe selection is left to the implementation plan; the requirement
  is that the file be immediately runnable end-to-end.
- `souji init` is an addition to the CLI surface, not a modification of any
  existing subcommand. The existing rule that no other Souji code path may create
  `$XDG_CONFIG_HOME/souji/scenario/` (parent-spec FR-007b) continues to hold for
  every command other than `init`.
- The generated file is plain UTF-8 Ruby source with no shebang and no execute
  bit; it is consumed by `souji plan` via `instance_eval`, not run as a script.
