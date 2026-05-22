# Phase 0 Research: Souji CLI

**Feature**: 001-souji-cli-recipe-plan
**Date**: 2026-05-22

## R1. Minimum Ruby version

**Decision**: `ruby >= 3.2.0` in `souji.gemspec`.

**Rationale**: Ruby 3.2 introduced `Data.define`, which we will use for the
immutable `Souji::PlanItem` and `Souji::Plan` value objects (cleaner than `Struct`
with explicit freezing). 3.2 is also widely available — current on Homebrew, default
or one-step-install on Ubuntu 24.04 / Debian Trixie / Fedora 40+, and the common
target on `rbenv` / `asdf` setups in 2026.

**Alternatives considered**:
- **Ruby 3.0/3.1**: no `Data.define`, would force `Struct`-with-freeze workarounds.
  Rejected — saves no real users (anyone still on 3.0 in 2026 can install 3.2).
- **Ruby 3.4 (latest)**: rejected — narrows compatibility for no concrete feature
  win in our use case. v1 can ratchet up later if a 3.4-only feature becomes
  attractive.

## R2. CLI argument parser

**Decision**: `thor` (~> 1.3) for the top-level CLI with subcommands.

**Rationale**: Souji has two clear subcommands (`plan`, `apply`) plus per-command
flags (`-o`, `--yes`, `--dry-run`, `--log-file`, `--json`). Thor handles
subcommand dispatch, help text generation, and option parsing with very little
ceremony, and it is the most widely understood CLI framework in the Ruby ecosystem
(used by Rails generators, Bundler, etc.). New contributors will recognize the
patterns immediately.

**Alternatives considered**:
- **`optparse` (stdlib)**: zero deps but requires hand-rolling subcommand
  dispatch and help. More boilerplate for negligible binary-size or install-speed
  benefit. Rejected.
- **`dry-cli`**: cleaner DSL but smaller community and another `dry-rb` dependency
  chain. Rejected for v1; can be reconsidered if Thor becomes a constraint.
- **`clamp`**: declarative and nice but obscure in Ruby-land. Rejected to keep
  the contributor on-ramp short.

## R3. Test framework

**Decision**: `rspec` (~> 3.13).

**Rationale**: The TDD discipline in Constitution Principle III rewards expressive
test names ("describes a behavior" rather than "asserts an output"). RSpec's
`describe`/`context`/`it` structure is more legible for the kinds of integration
tests we'll have (e.g., "given a scenario with an abandoned worktree, plan lists
it as a candidate"). It also has first-class support for shared examples (handy for
recipe contract tests) and tagged tests (so `:docker`-tagged integration tests can
be skipped on machines without docker).

**Alternatives considered**:
- **`minitest` (stdlib)**: lighter weight, no extra dep. Adequate technically but
  less idiomatic for behavior-driven test names. Rejected for v1; the dependency
  cost of RSpec is small for a dev-time gem.

## R4. Trash / safe-delete on macOS and Linux

**Decision**: `Souji::Trash` helper that shells out to platform commands when
available, with a hard-delete fallback that emits an explicit stderr warning.
Detection order:

1. macOS: `command -v trash` (Homebrew `trash` CLI from `ali-rantakari/trash`).
2. macOS fallback: `osascript -e 'tell application "Finder" to move ... to trash'`.
3. Linux: `command -v gio` + `gio trash <path>`.
4. Linux fallback: write to `$XDG_DATA_HOME/Trash/` per freedesktop spec (only if
   the spec gets simple enough to implement inline).
5. Last resort: `FileUtils.rm_r(path)` with a loud stderr message saying the item
   was permanently deleted because no trash mechanism was available.

Recipes whose resource is intrinsically non-trashable (e.g., docker image layers
managed by the docker daemon) opt out of `Souji::Trash` and document the
non-reversibility in their `Recipe#describe_action` output. This is explicit per
spec Assumptions.

**Rationale**: Most users on modern macOS / Linux have either the `trash` CLI
(Homebrew) or `gio` (GNOME / GTK ecosystem) available. The fallback chain keeps
the tool functional in headless / minimal environments without silently doing
something destructive. The explicit warning on hard-delete fallback satisfies
Constitution V's "no surprising irreversibility".

**Alternatives considered**:
- **Reimplement freedesktop trash spec inline**: feasible but adds 100+ lines of
  metadata-file handling for a v1 deliverable. Deferred.
- **`trash-cli` gem (Python-based)**: not a Ruby gem; would add a Python runtime
  dep. Rejected.
- **`platform-trash` Ruby gems on RubyGems.org**: none are actively maintained as
  of 2026. Rejected.

## R5. Recipe registry and extensibility pattern

**Decision**: Recipes inherit from `Souji::Recipe` (an abstract base). The base
class's `inherited(subclass)` hook registers each subclass into a class-level
registry keyed by `subclass.recipe_name`. Built-in recipes are autoloaded from
`lib/souji/recipes/*.rb` at gem-load time so they self-register without explicit
user action.

```ruby
class Souji::Recipes::GitWorktree < Souji::Recipe
  recipe_name "git-worktree"
  required_external_command "git"
  # ...
end
```

`Souji::Recipe.registry` returns `{name => class}`. The DSL's `recipe(name, ...)`
method looks the recipe up here.

**Rationale**: Idiomatic Ruby (matches Rails / RSpec / Thor patterns); zero
configuration; satisfies spec FR-003 (new recipes added without modifying
existing ones) and SC-006 (a new recipe touches < 3 files outside its own
directory — typically just `lib/souji/recipes.rb` for the autoload entry).

**Alternatives considered**:
- **Explicit imperative registration in a central file**: simpler but couples each
  recipe to an unrelated file, violating SC-006 spirit.
- **Filename-based discovery scanning `lib/souji/recipes/*.rb` at runtime**:
  works but loses static-analysis friendliness and adds runtime cost on every
  `souji` invocation.

## R6. DSL evaluation strategy

**Decision**: A `Souji::DSL::Context` instance hosts the DSL methods (`recipe`,
`target`, etc.) and the scenario file is evaluated with `instance_eval(File.read(path), path, 1)`.
The filename and line number are passed so backtraces from a buggy scenario point
at the user's file, not at Souji's internals. Per spec clarification Q1 (Trusted
full Ruby), there is no sandbox, method allow-list, or `$SAFE` use.

**Sketch**:

```ruby
module Souji::DSL
  class Context
    def initialize
      @invocations = []
    end

    def recipe(name, **opts, &blk)
      @invocations << RecipeInvocation.new(name:, opts:, block: blk)
    end

    def target(*paths)
      # accumulates target roots; scoped via with_targets do ... end
    end
    # ...
  end
end

Souji::DSL::Context.new.tap do |ctx|
  ctx.instance_eval(File.read(scenario_path), scenario_path, 1)
end
```

**Rationale**: The clarification explicitly rejected sandbox/restricted-DSL. Pass-
through `instance_eval` with filename annotation is the simplest pattern, gives
users full Ruby (loops, helpers, `require`), and yields clear errors.

**Alternatives considered**:
- **`Kernel#eval` with `binding`**: harder to scope DSL methods cleanly; rejected.
- **Parser-based DSL (`parser` gem + ast walk)**: massive over-engineering for v1;
  rejected.

## R7. Plan YAML schema and versioning

**Decision**: Plan files have a top-level `souji_plan_version: 1` field. Layout:

```yaml
souji_plan_version: 1
souji_version: "0.1.0"
generated_at: "2026-05-22T13:45:01+09:00"
scenario:
  path: "/Users/naruta/cleanups/weekly.rb"
  content_sha256: "ab12...ef"   # informational only per FR-011a
target_roots:
  - "/Users/naruta/work"
items:
  - id: "git-worktree:01HZ..."
    recipe: "git-worktree"
    path: "/Users/naruta/work/repo-a/.git/worktrees/feat-x"
    reason: "Worktree marked prunable by git (last accessed > 30d ago)"
    size_bytes: 248932
    metadata:
      commit: "abc1234"
      branch: "feat-x"
```

Each item's `id` is a stable, scoped identifier (`<recipe>:<ULID>`) generated at
plan time. Apply uses this `id` as the lookup key for re-verification (FR-015).

**Rationale**: The `souji_plan_version` field gives future-Souji a single switch
for backward-compatible parsing. `content_sha256` is informational per FR-011a.
ULIDs (Crockford base32) provide K-sortable, URL-safe identifiers — small enough
to be readable but unique. ULIDs avoid pulling in a uuid dep and are easy to
implement (8-byte timestamp + 10-byte randomness).

**Alternatives considered**:
- **No version field**: silent breakage when format evolves. Rejected.
- **JSON instead of YAML**: less human-readable for paths with special chars.
  Rejected per spec FR-009.
- **UUIDv7 ids**: equivalent benefits to ULID; either works. ULID picked because
  Crockford base32 is more compact in YAML.

## R8. External-command detection

**Decision**: A `Souji::Recipe.required_external_commands` declaration lets each
recipe list the executables it depends on. The framework probes availability at
recipe-invocation time via:

```ruby
def self.available?(cmd)
  system("command -v #{Shellwords.escape(cmd)} >/dev/null 2>&1")
end
```

If any required command is missing, the recipe contributes nothing to the plan
and emits one stderr line: `[souji] recipe '<name>' skipped: command '<cmd>' not found`.
Plan generation continues for other recipes (FR-020).

**Rationale**: `command -v` is POSIX and present on both macOS and Linux default
shells; it covers builtins/aliases that `which` may miss. Recipe-side declaration
keeps the framework agnostic to which tools each recipe needs.

**Alternatives considered**:
- **Calling `--version` on each tool**: noisier output and slower; rejected.
- **`Pathname#which` from `pathname` stdlib**: not a stdlib method; would require
  another gem. Rejected.

## R9. Apply-phase confirmation UX

**Decision**: Single bulk confirmation. Before any deletion, `apply` prints:

```text
Souji plan: /Users/naruta/cleanups/weekly.soujiplan
About to delete 17 items (estimated 412 MB):
  - git-worktree:    8 items
  - terraform-provider: 6 items
  - docker-image:    3 items
Proceed? [y/N]:
```

`y` (case-insensitive) proceeds. Anything else cancels with exit code 130
(user-cancelled). `--yes` skips the prompt. `--dry-run` reports the same summary
but does NOT prompt and does NOT delete.

**Rationale**: Per-item prompts are unusable for plans with hundreds of items.
Bulk confirmation with a per-recipe-category breakdown gives the user enough
information to reject quickly if something looks off. Exit code 130 matches the
convention for "process interrupted by SIGINT" and is the de-facto Unix idiom for
user-cancelled.

**Alternatives considered**:
- **Per-item confirmation as default**: hostile UX. Rejected.
- **Two-phase prompt (confirm count, then confirm again)**: unnecessary friction
  given that plan itself already serves as a deliberate first phase. Rejected.

## R10. Action log format

**Decision**: JSON Lines (one JSON object per line), emitted to BOTH stderr
AND a file under `$XDG_STATE_HOME/souji/log/<UTC-timestamp>-<plan-basename>.jsonl`
by default. `--log-file <path>` overrides the file destination; `--no-log-file`
suppresses the file (stderr-only). See R12/R13 for the XDG rationale. Each
line:

```json
{"ts":"2026-05-22T13:50:00.123+09:00","item_id":"git-worktree:01HZ...","recipe":"git-worktree","path":"/.../feat-x","outcome":"deleted","duration_ms":42}
```

Outcomes: `deleted`, `trashed`, `skipped` (with `reason` field), `failed` (with
`error` field). One terminal summary line: `{"summary":true,"deleted":15,"trashed":0,"skipped":1,"failed":1,"duration_ms":18342}`.

**Rationale**: JSONL is trivial to parse, append-safe, and tool-friendly (`jq`,
shell pipelines). Stderr keeps stdout clean for any future scripting use of
souji's primary output.

**Alternatives considered**:
- **Free-form text log**: harder to programmatically post-process; rejected.
- **Single JSON document built up in memory**: loses partial-failure data if
  apply crashes mid-flight; rejected.

## R11. Recipe-specific implementation notes

Brief — full implementation is `/speckit-tasks` territory, but the research
needs to confirm each recipe is tractable for v1.

**git-worktree**:
- Use `git worktree list --porcelain` against each git directory under the scope.
- A worktree is a candidate when `prunable` appears in the porcelain output, OR
  when the worktree directory is missing on disk but still registered. Conservative
  default: only consider entries flagged `prunable` by git itself.
- Deletion: `git worktree remove --force <path>` rather than `rm -rf`, so git's
  metadata is also cleaned up.
- External command required: `git`.

**terraform-provider**:
- Inspect `~/.terraform.d/plugin-cache/` (default) or the `plugin_cache_dir`
  config. The cache layout is
  `plugin-cache/<hostname>/<namespace>/<name>/<version>/<os_arch>/...`.
- A provider version is a candidate when no `.terraform.lock.hcl` under the
  scenario's target roots references it. Scan all `.terraform.lock.hcl` files
  in scope; build a set of referenced `{name, version}` pairs; flag the
  unreferenced cache entries.
- Deletion: filesystem removal (via Souji::Trash) of the per-version directory.
- External command required: none (pure filesystem + HCL parsing of `.lock.hcl`).
  HCL parsing in `.lock.hcl` is line-based and trivial; we avoid pulling in an
  HCL gem.

**docker-image**:
- Use `docker images --digests --format '{{json .}}'` to enumerate images.
- A candidate is a `<none>:<none>` (dangling) image OR an image with no
  associated container (`docker ps -a --filter ancestor=<id> -q` returns empty).
  The conservative v1 definition: dangling images only. Other heuristics
  (last-used-time, build-cache age) can be added in later iterations.
- Deletion: `docker image rm <id>`. This is NOT trash-able; the recipe documents
  this in its apply-time output.
- External command required: `docker`.

**Rationale**: All three recipes are achievable with shell-out + line parsing,
no third-party Ruby gems for git/docker/terraform integration. Keeping the
external surface to "real CLI subprocesses" matches Constitution Principle IV
(integration testing against real boundaries) and avoids brittle library bindings.

## R12. XDG Base Directory conventions

**Decision**: Souji follows the XDG Base Directory Specification for default
file locations:

- Scenarios: `$XDG_CONFIG_HOME/souji/scenario/<name>.rb`, defaulting
  `$XDG_CONFIG_HOME` to `~/.config` when the env var is unset or empty.
- Plan output: `$XDG_CACHE_HOME/souji/<name>.soujiplan`, defaulting
  `$XDG_CACHE_HOME` to `~/.cache` when unset or empty.

Name resolution for both `<scenario>` (in `souji plan`) and `<plan-file>` (in
`souji apply`) follows a single rule (spec FR-007a):

1. Argument contains `/`, starts with `~`, or ends with `.rb` / `.soujiplan`
   → treated as a filesystem path.
2. Otherwise → bare name, looked up under the XDG directory above.

The cache directory (`$XDG_CACHE_HOME/souji/`) is created on demand by `souji
plan`. The config directory (`$XDG_CONFIG_HOME/souji/scenario/`) is NOT
auto-created — the user explicitly populates it.

Action log destination (R13) extends the XDG mapping: by default, apply writes
the JSONL action log to `$XDG_STATE_HOME/souji/log/<UTC-timestamp>-<plan-basename>.jsonl`
in addition to stderr.

**Rationale**: XDG is the de-facto standard for CLI tools on Linux and is
well-supported on macOS via env vars. Using `~/.cache` (not `~/.local/share`)
for plans reflects that plans are regenerable: nothing under `~/.cache/souji/`
is sacrosanct, and a user clearing their cache should not lose anything
important. The single name-resolution rule (path-shape vs bare name) keeps
the CLI predictable: `souji plan weekly` and `souji plan ./weekly.rb` are
unambiguous and never depend on whether the CWD happens to contain a file
named `weekly`.

**Alternatives considered**:

- **Search both CWD and XDG**: ambiguous when both exist; a typo in CWD could
  silently shadow the XDG scenario. Rejected.
- **Use `~/.souji/`**: pre-XDG style. Rejected — disrespects $XDG_*_HOME
  overrides users commonly set to redirect their config / cache out of `~`.
- **Plans under `~/.local/share/souji/`**: that's `$XDG_DATA_HOME`, intended
  for data the user is expected to back up. Plans are derivable artifacts,
  not user data. Cache is the right bucket.

## R13. Action log default location (XDG_STATE_HOME)

**Decision**: `souji apply` writes the JSONL action log to BOTH stderr and a
file at `$XDG_STATE_HOME/souji/log/<UTC-timestamp>-<plan-basename>.jsonl`
(defaulting `$XDG_STATE_HOME` to `~/.local/state` when unset).

- **Filename**: UTC timestamp in `YYYY-MM-DDTHH-MM-SSZ` form (colons replaced
  with dashes for filesystem safety; UTC so lexicographic order = chronological
  order) plus the plan basename so a user with multiple scenarios can find a
  specific run quickly.
- **Override**: `--log-file <path>` writes to the given path instead;
  `--no-log-file` suppresses the file. Stderr emission is unchanged in all
  cases.
- **Best-effort**: directory creation or file open failure (read-only FS,
  permission denied) MUST NOT block apply. Souji prints a one-line stderr
  warning and continues with stderr-only emission (spec FR-017a, Edge Case
  "Log directory unwritable").
- **No rotation in v1**: log files accumulate. If they ever become a
  problem, users can author a Souji scenario to clean them up — appropriately
  recursive, given Souji is a cleanup tool.

**Rationale**: Apply is destructive. A persistent audit trail by default is in
keeping with Constitution Principle V (Safety by Default) — being able to
answer "what did I delete on 2026-05-20?" two weeks later is a real concern.
JSONL is append-safe and `jq`-friendly. UTC timestamps in filenames sort
correctly and avoid timezone confusion when machines move between zones.
Best-effort persistence prevents a misconfigured `$XDG_STATE_HOME` (e.g.,
mounted read-only inside a container) from blocking legitimate cleanup work.

**Alternatives considered**:

- **File-only by default (no stderr)**: loses live progress feedback during
  interactive apply. Rejected.
- **Single appended log file (`apply.jsonl`) instead of per-run files**:
  Hard to attribute lines to runs after the fact, and recovery from partial
  apply failure is messier. Rejected.
- **Default location under `$XDG_DATA_HOME`**: violates XDG semantics —
  action logs are state (regenerable-ish per-run state), not user-curated
  data. Rejected.
- **Default location under `$XDG_CACHE_HOME`**: cache implies "safe to
  wipe at any time" but the audit purpose contradicts that. `$XDG_STATE_HOME`
  is the right bucket for "log of what this user did, persistent across runs."
  Rejected.
- **Truncate or rotate at N files**: introduces magic; let the user decide.
  Rejected.

## Open / deferred items

These were intentionally not researched because they are out of scope for the v1
spec; recording here so they don't get re-discovered later:

- **Third-party recipe distribution** (gem-based, plugin registry): spec
  Assumptions exclude this from v1. Deferred.
- **Per-item interactive confirmation in apply**: deferred (R9 picked bulk).
- **Concurrent-apply locking**: spec Edge Cases say "skipped if already deleted",
  which avoids the destructive race; full locking with a `.souji.lock` file is
  not in scope for v1.
- **Windows support**: explicitly out of scope (spec Assumptions).
- **System-wide scenario search path** (`$XDG_CONFIG_DIRS/souji/scenario/`):
  enable team-deployed cleanup scenarios via configuration management. Deferred.
- **User-level `config.yml`** under `$XDG_CONFIG_HOME/souji/`: would hold
  cross-invocation defaults (preferred trash mechanism, default
  `--target-root`s, etc.). No concrete need in v1; deferred.
- **Log rotation / pruning**: Souji v1 does not rotate log files. A future
  built-in recipe (e.g., `souji-log-age`) could let users prune via the same
  plan/apply machinery, dog-fooding the cleanup engine. Deferred.
- **Concurrent-apply locking** via `$XDG_RUNTIME_DIR/souji/apply.lock`: spec
  Edge Cases handle the race by per-item skip, so a runtime lock is not
  required for safety. Deferred.
