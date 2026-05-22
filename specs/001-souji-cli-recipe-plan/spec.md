# Feature Specification: Souji CLI — Recipe-based Plan & Apply

**Feature Branch**: `001-souji-cli-recipe-plan`

**Created**: 2026-05-22

**Status**: Draft

**Input**: User description: "souji は ruby で書かれた cli ツール。ローカルディスクのディレクトリをクロールし、不要なファイルやディレクトリを見つけ出す。削除戦略を \"recipe\" と呼び、たとえば git-worktree recipe は対象リポジトリのディレクトリに置いて不要になった worktree を発見して削除対象にする。いま計画しているレシピは git-worktree / terraform-provider / docker-image など。これらのレシピを参照する削除シナリオファイルをユーザが Ruby DSL で書く。souji plan <scenario> -o soujiplan、souji apply soujiplan のように 2 フェーズで削除を実行する。プランファイルは人間が読めるように yaml で出力する"

## Clarifications

### Session 2026-05-22

- Q: Ruby DSL ファイルの読み込み・評価モデルは？ → A: Trusted full Ruby — シナリオは信頼されたユーザーが書く前提で、`instance_eval` 等を用いて Ruby をそのまま評価する。サンドボックスや restricted DSL は導入しない。
- Q: apply 時にシナリオハッシュが plan 生成時と異なっていた場合の振る舞いは？ → A: apply は plan ファイルのみを source of truth として動作する。apply 中に scenario ファイルを再ロード・再評価することはなく、scenario の差分検証は行わない。新鮮さの検証は FR-015 の per-item recipe re-verification に一本化する。
- Q: 外部コマンド (git / terraform / docker) が不在・使用不可なときの振る舞いは？ → A: 該当 recipe のみをスキップし、stderr で警告。plan 全体は他の recipe を継続実行して完走させる (隔離制を担保)。
- Q: シナリオファイルと plan 出力ファイルのデフォルト配置は？ → A: XDG Base Directory 規約に従う。シナリオは `$XDG_CONFIG_HOME/souji/scenario/<name>.rb` (デフォルト `~/.config/souji/scenario/`) からの名前解決、plan 出力は `$XDG_CACHE_HOME/souji/<name>.soujiplan` (デフォルト `~/.cache/souji/`) に書き出す。引数が `/` を含む / `~` で始まる / `.rb` で終わる場合は従来通りファイルパスとして扱い、それ以外は裸の名前として XDG ディレクトリ配下を探索する。これは `souji plan` の入出力と `souji apply` の plan 入力の両方に適用する。
- Q: apply の action log は audit のためデフォルトでファイルに残すべきか？ → A: 残す。デフォルトで `$XDG_STATE_HOME/souji/log/<UTC-timestamp>-<plan-basename>.jsonl` (デフォルト `~/.local/state/souji/log/`) に JSONL で書き出し、同時に stderr にも流す (現状の振る舞いは維持)。`--log-file <path>` で書き出し先を上書きでき、`--no-log-file` でファイル書き出しを無効化できる (stderr のみ)。`$XDG_STATE_HOME/souji/log/` は apply 時に on-demand 作成する。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Preview cleanup candidates from a scenario (Priority: P1)

A developer has accumulated cruft on their workstation (stale git worktrees, unreferenced
provider caches, dangling container image layers). They have written — or been handed —
a scenario file describing what they want cleaned. Before deleting anything, they want
to see a precise, human-readable list of everything that would be removed.

The developer runs `souji plan <scenario> -o <plan-file>`. Souji crawls the directories
referenced by the scenario, applies each recipe's detection logic, and writes a
human-readable plan file enumerating every candidate (path, size, the recipe that
identified it, and the reason). Nothing on disk is modified.

**Why this priority**: This is the entire safety story of the tool. Even without the
apply phase, a developer who can run `plan` already gets value: they see what is wasting
space and can act on it themselves. It is also the MVP that makes Principle V (Safety by
Default) demonstrable.

**Independent Test**: Given a scenario that references at least one recipe and a target
directory containing detectable cruft, running the plan command produces a non-empty
plan file that lists exactly the items the recipe would target, while the target
directory's contents remain byte-for-byte identical before and after. Verifiable by
diffing the directory state and by reading the plan file.

**Acceptance Scenarios**:

1. **Given** a scenario file that invokes the `git-worktree` recipe against a directory
   containing one active worktree and two abandoned worktrees, **When** the user runs
   `souji plan <scenario> -o cleanup.yaml`, **Then** `cleanup.yaml` exists, is valid
   human-readable structured text, lists exactly the two abandoned worktrees with their
   paths and the recipe that flagged them, and the active worktree is not listed.
2. **Given** the same scenario as above, **When** the user inspects the target directory
   immediately after running plan, **Then** every file and worktree present before the
   command is still present and unchanged.
3. **Given** a scenario that finds no candidates, **When** the user runs plan, **Then**
   the plan file is still produced, parses cleanly, contains zero deletion items, and
   the command exits with a success status code.
4. **Given** a scenario that references a recipe name that does not exist, **When** the
   user runs plan, **Then** the command exits with a non-zero status, writes a
   diagnostic to stderr naming the unknown recipe, and no plan file is created.

---

### User Story 2 - Apply a previously generated plan (Priority: P2)

The developer has reviewed the plan file from User Story 1 and decided the deletions
are correct. They want to execute those deletions in a controlled, confirmable way.

The developer runs `souji apply <plan-file>`. Souji reads the plan, presents a summary
of what is about to be removed, requires explicit confirmation, then removes each
listed item. For each item, Souji re-verifies that the item still matches the
recipe's criteria at apply time; items that have already been deleted or no longer
match are skipped and reported, not treated as errors. Souji emits a structured
record of every action it takes (what was deleted, what was skipped, why).

**Why this priority**: Apply is the value-realization step — it is what actually frees
space. It is P2 because plan alone is already useful, and because apply carries the
destructive risk that the rest of the safety machinery exists to contain.

**Independent Test**: Given a valid plan file generated against a known target
directory, running `souji apply` against that plan removes exactly the items in the
plan and nothing else, and produces a structured action log that accounts for every
plan item (deleted, skipped, or failed). Verifiable by diffing the target directory
state against the plan's deletion list and by parsing the action log.

**Acceptance Scenarios**:

1. **Given** a plan file listing two specific worktree directories for deletion,
   **When** the user runs `souji apply <plan>` and confirms when prompted, **Then**
   exactly those two directories are removed, no other directory under the target
   path is modified, and the action log records both removals.
2. **Given** the same plan file, **When** the user runs `souji apply <plan>` and
   declines the confirmation prompt, **Then** no files are removed and the command
   exits with a non-zero status indicating cancellation.
3. **Given** a plan file in which one of the listed items was already deleted by an
   unrelated process between plan and apply, **When** the user runs apply, **Then**
   the missing item is reported as skipped (not as a failure), the remaining items
   are still deleted, and apply exits with success.
4. **Given** any plan file, **When** the user runs `souji apply --dry-run <plan>`,
   **Then** Souji reports what it would delete but performs no deletions, regardless
   of confirmation.

---

### User Story 3 - Author cleanup scenarios in a Ruby DSL (Priority: P3)

A developer wants to define a reusable cleanup policy that combines multiple recipes
against multiple target directories — for example, "clean abandoned worktrees under
`~/work`, prune unreferenced AWS provider caches in `~/work/**/*`, and trim docker
image layers older than 30 days." They want to keep this policy in a file they can
edit, version-control, and re-run.

The developer writes a scenario file using Souji's Ruby DSL. The DSL gives them
declarative constructs to reference recipes by name, point recipes at target
directories, and pass recipe-specific parameters. They invoke the scenario via
`souji plan <scenario-path> -o <plan>` and re-use the same scenario file over
time.

**Why this priority**: Scenarios are how the tool scales beyond ad-hoc one-off use.
P3 because US1 and US2 can ship first with built-in or trivial scenarios; the
scenario authoring affordance is what unlocks customization and team-wide reuse.

**Independent Test**: Given a scenario file that references multiple recipes against
multiple target directories, running plan produces a plan that contains candidates
from each recipe with the correct attribution, demonstrating that the DSL successfully
composes recipes. Verifiable by inspecting the plan file's structure and recipe
attribution.

**Acceptance Scenarios**:

1. **Given** a scenario file that invokes the `git-worktree` recipe against one
   directory and the `docker-image` recipe with no directory argument, **When** the
   user runs plan, **Then** the resulting plan contains deletion candidates from both
   recipes, each candidate is labelled with the recipe that produced it, and the
   ordering is deterministic across re-runs against unchanged inputs.
2. **Given** a scenario file with a syntax error, **When** the user runs plan,
   **Then** the command exits with a non-zero status and stderr clearly identifies
   the file and (where available) the line at fault; no plan file is written.

---

### Edge Cases

- **Stale plan**: A plan file is applied long after it was generated, and the
  filesystem has changed. Apply must not destroy items that no longer match the
  recipe's criteria (e.g., a worktree that has been reactivated). Apply re-verifies
  each item against the originating recipe before deleting.
- **Plan / apply machine mismatch**: A plan generated on one machine is applied on
  another with different paths. Apply does not consult the scenario (FR-011a), so
  it cannot reject the plan on scenario grounds; instead it relies on per-item
  recipe re-verification (FR-015), which will fail to re-confirm candidates whose
  paths cannot be resolved or no longer match recipe criteria, causing those items
  to be skipped rather than mistakenly acted on.

- **Scenario edited after plan**: The user edits the scenario file between `plan`
  and `apply`. Apply does NOT detect or react to this — the plan file is the
  source of truth (FR-011a). The scenario content hash recorded in plan metadata
  exists for human audit only, not for apply-time enforcement.

- **External command unavailable**: A recipe requires `docker` but docker is not
  installed on the workstation. Plan skips that recipe with a stderr warning and
  produces a plan covering the remaining recipes (FR-020); apply consumes only
  what plan emitted, so the missing tool surfaces once at plan time.
- **Concurrent invocation**: Two `apply` runs against the same plan file at the
  same time. Apply must not corrupt the action log and must not double-delete (a
  second deletion of an already-removed path is reported as skipped, not failed).
- **Partial failure**: Half-way through apply, a deletion fails (permission denied,
  IO error). Apply continues with remaining items, records the failure in the action
  log, and exits with a non-zero status that reflects there was at least one failure.
- **Empty scenario**: A scenario file that references no recipes or no targets.
  Plan produces an empty plan file and exits successfully, with a stderr note that
  no candidates were considered.

- **Bare-name scenario missing under XDG config**: User runs `souji plan weekly`
  but `$XDG_CONFIG_HOME/souji/scenario/weekly.rb` does not exist. Souji exits
  with code 2 and stderr names the exact path it tried, so the user can tell
  "I typo'd the name" from "I haven't created the file yet" (FR-007a).

- **Bare-name plan missing under XDG cache**: User runs `souji apply weekly`
  before ever running `souji plan weekly`. Same behavior as above — exit code
  2 with the tried path on stderr.

- **Log directory unwritable**: `$XDG_STATE_HOME/souji/log/` cannot be created
  or written (read-only filesystem, permission denied). Apply MUST NOT abort —
  it falls back to stderr-only emission, prints a one-line warning naming the
  path, and continues with the requested deletions. The audit trail being
  best-effort MUST NOT block the actual cleanup, but the failure MUST be
  visible.
- **Path outside scope**: A recipe attempts to flag a path outside the scenario's
  declared target roots. The plan must omit such items and report the attempt in
  stderr; apply must never touch them even if they appear in a hand-edited plan.

## Requirements *(mandatory)*

### Functional Requirements

**Recipe model**

- **FR-001**: The system MUST treat each cleanup strategy as a named, independently
  invokable "recipe". A recipe defines (a) what category of cruft it identifies and
  (b) how, given a target directory and parameters, it enumerates deletion
  candidates.
- **FR-002**: The system MUST ship with the following built-in recipes at launch:
  `git-worktree`, `terraform-provider`, `docker-image`. Each MUST be runnable from a
  scenario without additional setup.
- **FR-003**: The system MUST allow new recipes to be added without modifying
  existing recipes or the scenario-DSL surface. (Extensibility is required;
  third-party recipe distribution mechanism is out of scope for v1 — see
  Assumptions.)

**Scenario authoring**

- **FR-004**: Users MUST be able to author cleanup scenarios as Ruby DSL files. The
  DSL MUST allow referencing recipes by name, scoping recipes to one or more target
  directories, and passing recipe-specific parameters.
- **FR-005**: The DSL MUST be self-contained: a scenario file MUST run without
  requiring the user to write or wire up auxiliary Ruby code beyond the DSL
  constructs Souji exposes.
- **FR-005a**: Scenario evaluation MUST treat the scenario file as trusted Ruby
  source authored by the invoking user. Souji MAY evaluate the scenario with
  `instance_eval` (or equivalent) without sandboxing or method-allow-list
  restrictions. The threat model explicitly EXCLUDES executing untrusted /
  third-party scenarios; users are responsible for reviewing scenario files
  before invoking `plan` against them.
- **FR-006**: A scenario file MUST be deterministic: given identical filesystem
  state, two runs of `plan` against the same scenario MUST produce equivalent plan
  files (same candidates, same ordering of candidates).

**Plan phase**

- **FR-007**: The system MUST provide a `souji plan <scenario> [-o <plan-file>]`
  command that crawls the directories referenced by the scenario, invokes each
  recipe, and writes a plan file enumerating deletion candidates. The
  `<scenario>` argument and the `-o` value follow the XDG name resolution rules
  in FR-007a.
- **FR-007a**: Souji MUST resolve the `<scenario>` argument of `souji plan` and
  the `<plan-file>` argument of `souji apply` as follows:
  1. If the argument contains a path separator (`/`), starts with `~`, or ends
     with `.rb` (scenarios) / `.soujiplan` (plans), it MUST be treated as a
     filesystem path and resolved against the current working directory.
  2. Otherwise (a "bare name"), Souji MUST treat the argument as a name and
     look it up under the user's XDG directory:
     - Scenarios: `$XDG_CONFIG_HOME/souji/scenario/<name>.rb`, defaulting
       `$XDG_CONFIG_HOME` to `~/.config` when unset.
     - Plans: `$XDG_CACHE_HOME/souji/<name>.soujiplan`, defaulting
       `$XDG_CACHE_HOME` to `~/.cache` when unset.
  3. When the resolved file does not exist, Souji MUST exit with a usage error
     (exit code 2) whose stderr message includes the path that was tried, so
     the user can distinguish "I typo'd the name" from "I haven't created the
     file yet".
- **FR-007b**: When `souji plan` is invoked with a bare-name `<scenario>` and
  `-o` is omitted, the default output path MUST be
  `$XDG_CACHE_HOME/souji/<name>.soujiplan` (with the same XDG fallback as
  above). When `<scenario>` is a filesystem path and `-o` is omitted, the
  default output path MUST be `$XDG_CACHE_HOME/souji/<basename-without-ext>.soujiplan`.
  Souji MUST create `$XDG_CACHE_HOME/souji/` on demand if it does not exist;
  it MUST NOT create `$XDG_CONFIG_HOME/souji/scenario/` (the config directory
  is the user's to provision).
- **FR-008**: `plan` MUST NOT modify any file or directory on disk. Read-only
  filesystem operations only.
- **FR-009**: The plan file MUST be a human-readable, structured text file (YAML).
  A reader unfamiliar with Souji's internals MUST be able to read a plan and
  understand what would be deleted and why.
- **FR-010**: For each deletion candidate, the plan MUST record at minimum: the
  absolute path; the recipe that flagged it; a short human-readable justification
  ("worktree marked prunable", "provider cache unreferenced for 90+ days", etc.);
  and an item-level identifier sufficient for apply to refer back to it.
- **FR-011**: The plan MUST record top-level metadata for audit and reproducibility:
  scenario file path (at time of plan), scenario content hash (informational only,
  see FR-011a), plan generation timestamp, Souji version, and the declared target
  root(s). The metadata exists so that a human reading the plan can identify which
  scenario produced it; apply does not enforce it (see FR-011a).
- **FR-011a**: `apply` MUST treat the plan file as the sole source of truth. `apply`
  MUST NOT re-load, re-evaluate, or otherwise consult the scenario file. The
  scenario content hash in plan metadata is informational only and MUST NOT be
  validated at apply time. Freshness of each deletion candidate is enforced solely
  by per-item recipe re-verification (FR-015).

**Apply phase**

- **FR-012**: The system MUST provide a `souji apply <plan-file>` command that
  performs the deletions enumerated in the plan.
- **FR-013**: `apply` MUST require explicit user confirmation before performing any
  deletion. The default invocation MUST be interactive; non-interactive operation
  MUST require an explicit opt-in flag (e.g., `--yes`).
- **FR-014**: `apply` MUST provide a `--dry-run` mode that reports what would be
  deleted without performing any deletion, regardless of confirmation.
- **FR-015**: Before deleting each item, `apply` MUST re-verify against the
  originating recipe that the item still qualifies for deletion. Items that no
  longer qualify MUST be skipped (not failed) and reported in the action log.
- **FR-016**: `apply` MUST refuse to delete any path that is not enumerated in the
  plan file. (Hand-editing a plan to add arbitrary paths MUST NOT broaden apply's
  delete scope beyond what the originating recipe would have produced.)
- **FR-017**: `apply` MUST emit a structured action log that, for every plan item,
  records the outcome (deleted, skipped, failed) and, on failure, the reason.
- **FR-017a**: `apply` MUST write the action log to a file under
  `$XDG_STATE_HOME/souji/log/` (defaulting `$XDG_STATE_HOME` to
  `~/.local/state` when unset) by default, IN ADDITION to streaming it to
  stderr. The default filename MUST encode the UTC timestamp of the apply
  invocation and the plan's basename, so two runs against the same plan never
  collide (e.g., `2026-05-22T13-50-00Z-weekly.jsonl`). Souji MUST create
  `$XDG_STATE_HOME/souji/log/` on demand if it does not exist.
- **FR-017b**: The user MUST be able to override the log destination with
  `--log-file <path>` (writes to `<path>` instead of the XDG default; stderr
  emission unchanged) and MUST be able to suppress file output entirely with
  `--no-log-file` (stderr emission unchanged; no file is written). Passing
  both `--log-file <path>` and `--no-log-file` is a usage error (exit code 2).

**Safety & observability (cross-cutting)**

- **FR-018**: All commands MUST emit human-readable output on stdout and diagnostic
  output on stderr, and MUST set exit codes that distinguish success, expected
  failure (user cancelled, nothing to do), and unexpected failure.
- **FR-019**: Recipes MUST NOT enumerate or operate on paths outside the target
  roots declared in the invoking scenario.
- **FR-020**: When a recipe's required external command (e.g., `git`, `terraform`,
  `docker`) is absent or fails its availability probe, Souji MUST skip ONLY that
  recipe's contribution and continue executing the remaining recipes in the
  scenario. The skipped recipe MUST be reported on stderr with the recipe name and
  the underlying reason. The command's exit code MUST still indicate success if no
  other failures occurred, so that "expected absence" (e.g., docker not installed
  on this workstation) does not turn into a hard failure of unrelated cleanup work.

### Key Entities

- **Recipe**: A named cleanup strategy. Has a stable identifier (e.g.,
  `git-worktree`), a detection function that takes a target directory plus
  parameters and returns deletion candidates, and a verification function used by
  apply to re-confirm a candidate before deletion.
- **Scenario**: A user-authored Ruby DSL file. Declares one or more recipe
  invocations, each scoped to one or more target directories, with optional
  parameters. The source of truth for what plan will consider.
- **Plan**: A YAML document produced by `plan`. Records scenario metadata plus an
  ordered list of deletion candidates. Consumed by `apply`. Human-readable.
- **Plan Item**: A single deletion candidate within a plan: path, recipe
  attribution, justification, and a per-item identifier.
- **Action Log**: A structured record of what `apply` did, item by item. Used for
  audit and for diagnosing partial failures.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For 100% of supported recipes, running `plan` against a directory
  with known cruft produces a plan whose deletion list matches a hand-verified
  expected list (recipe correctness end-to-end).
- **SC-002**: A user unfamiliar with Souji can read a generated plan file and, in
  under 1 minute, correctly state which paths would be removed and why (plan
  readability).
- **SC-003**: Running `plan` against any scenario produces zero filesystem
  modifications under the target roots, verified by content-hash comparison
  before and after across 100% of plan runs in CI (safety invariant).
- **SC-004**: For an unchanged scenario and unchanged target directory, two
  back-to-back `plan` runs produce plans whose deletion lists are byte-identical
  after normalization of timestamps (determinism).
- **SC-005**: `apply` never deletes a path that does not appear in the input plan;
  verified by tests that hand-edit a plan to add an out-of-scope path and confirm
  apply refuses or skips it (containment).
- **SC-006**: Adding a new recipe requires changes to fewer than 3 existing files
  outside the new recipe's own directory (extensibility).

## Assumptions

- The tool runs on developer workstations (macOS and Linux). Windows is out of
  scope for v1.
- Ruby is acceptable both as the implementation language and as the scenario
  authoring language (per user direction). Scenarios are evaluated as trusted
  Ruby; Souji does not sandbox or restrict the DSL surface (see FR-005a). Users
  authoring or sharing scenarios are responsible for reviewing them before
  invoking `plan`.
- Recipe distribution: v1 ships only the built-in recipes (`git-worktree`,
  `terraform-provider`, `docker-image`). The internal recipe API is designed to
  permit additional recipes, but a public extension or plugin mechanism (gem-based
  third-party recipes, recipe marketplace, etc.) is out of scope for v1.
- The user has direct read/write access to the directories listed in their
  scenario; permission elevation, sudo, or remote-host operation is out of scope.
- Scenario and plan resolution follows the XDG Base Directory Specification per
  FR-007a / FR-007b. Bare names are resolved relative to
  `$XDG_CONFIG_HOME/souji/scenario/` (scenarios) and
  `$XDG_CACHE_HOME/souji/` (plans); fully qualified paths bypass XDG. There is
  intentionally no "search both XDG and CWD" fallback because the explicit
  rule keeps `souji plan weekly` and `souji plan ./weekly.rb` unambiguous.
- Plan files default to UTF-8 encoded YAML. When `-o` is omitted the default
  output path is `$XDG_CACHE_HOME/souji/<name>.soujiplan` per FR-007b.
- Action logs default to `$XDG_STATE_HOME/souji/log/<UTC-timestamp>-<plan-basename>.jsonl`
  per FR-017a (in addition to stderr). Souji creates
  `$XDG_STATE_HOME/souji/log/` on demand. Log files are not auto-rotated or
  pruned in v1; users who want them cleaned up can author a Souji scenario
  that targets the log directory (eat your own dog food).
- For deletions of files (as opposed to whole directories), Souji prefers
  reversible mechanisms (trash / `~/.Trash` on macOS, freedesktop trash on Linux)
  by default per Constitution Principle V; recipes that intrinsically operate on
  non-trashable resources (e.g., docker image layers) document this in their
  apply-time output.
- Recipe detection logic is independent: one recipe's results do not depend on
  another recipe having run. This keeps scenarios composable.
