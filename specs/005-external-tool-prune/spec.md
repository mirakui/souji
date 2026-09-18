# Feature Spec: delegated cache pruning and expanded docker coverage

**Status**: implemented
**Date**: 2026-09-18
**Affects**: `lib/souji/external/{command,human_size,docker,delegated_prune}.rb`,
`lib/souji/recipes/{uv_cache,pnpm_store,brew_cache,mise_version,go_cache,docker_container,docker_build_cache}.rb`,
`lib/souji/recipes/docker_image.rb`, `lib/souji/recipe.rb`, `lib/souji/scenario.rb`,
`lib/souji/plan.rb`, `lib/souji/commands/apply_prompt.rb`, `lib/souji/cli.rb`,
`lib/souji/commands/init_command.rb`, `README.md`, the `001` contracts

## Problem

The cleanup runbook that motivated `specs/004` also prunes tool-managed
caches by hand — roughly 20 GB across uv, pnpm, go, Homebrew and mise — and
docker's unused resources, roughly 16 GB. souji covered none of it except
dangling images.

These are not the same shape as `specs/004`'s work. A `node_modules/` is a
directory souji can measure and move to the trash. `~/.cache/uv` is a
content-addressable store with its own index, and the question "what here is
unreferenced?" is one only uv can answer.

## Goals

- Reclaim the runbook's tool caches by asking each tool to prune its own
  store, so no tool's index is left describing files that are gone.
- Cover the runbook's remaining docker lines.
- Never report bytes as freed that will not be freed.
- Make the exception to souji's containment promise a declaration the
  framework checks, rather than a convention implied by a URI.

## Non-goals

- **`docker-volume`.** The runbook deliberately refuses `--volumes`.
  Anonymous volumes are the highest-regret deletion class on a dev box:
  `docker volume ls` cannot tell a database's data directory from scratch
  space, and sizing them needs the much slower `docker system df -v`. If it
  is ever added it should require both an `anonymous_only:` and an
  `older_than_days:` opt-in and stay out of the README's recommended
  scenario.
- **A single `tool-cache` recipe.** See D1.
- **Migrating `Souji::Git::Command`** onto the new external layer. See D9.
- **A scenario-level gate for scope-free recipes.** See D8.
- **Resetting a docker VM's disk image.** Recovering the space pruning
  leaves inside the VM means destroying every image and volume in it. souji
  explains the situation and stops there.

## Decisions

### D1. One recipe per tool, not one `tool-cache` recipe

`required_external_commands` is a class-level declaration and it is
all-or-nothing: `Scenario#run_plan` skips the whole invocation when any
declared command is missing. A single recipe declaring `uv go pnpm brew mise`
would be skipped entirely on any machine lacking one of the five — which is
every CI runner and most machines. That is a correctness failure, not a
matter of style.

The workaround — declare nothing and probe with `Recipe.available?` inside
`#enumerate` — throws away the very thing FR-020 provides: the user gets no
note saying which tool was skipped, because `Progress#recipe_skipped` is only
reachable from the scenario.

Per-tool recipes also make the unit of consent match the unit of risk (D3),
and give per-tool counts in `souji recipes`, the README table, the plan's
`recipe:` field, `Plan#summary` and the action log for free.

### D2. What an item is, per tool

| Recipe | Granularity | Why |
|---|---|---|
| `uv-cache` | one opaque item | No `--dry-run`, no enumeration API. Anything finer would mean souji deciding what is unreachable, which is the judgement being delegated. |
| `pnpm-store` | one opaque item | Same. `pnpm store status` is a *tamper* check — whether stored packages were modified — not a statement about what is reclaimable, so it is not used. |
| `brew-cache` | one opaque item, real size | `--dry-run` enumerates and totals, but `brew cleanup` has no per-file mode. One item per path would give each item a `#delete` that re-ran the whole cleanup and removed the other items as a side effect, breaking the per-item contract. The listing becomes `size_bytes` plus the first 20 paths in metadata. |
| `mise-version` | **per version** | The only tool in the set that both enumerates prunable units (`mise ls --prunable --json`) and removes exactly one (`mise uninstall <tool>@<version>`). |
| `go-cache` | one item per requested half, **zero by default** | No enumeration, and the two halves differ too much in cost to merge (D4). |
| `docker-container` | **per container** | `docker ps -a --size` enumerates with real per-container sizes. |
| `docker-build-cache` | one opaque item | See D6. |

### D3. `size_bytes` means "will actually be freed on this host"

`Plan#summary` sums `size_bytes` into the figure the apply prompt puts in
front of the user. So only figures souji believes will materialise belong
there, and two kinds do not:

- **Unmeasurable.** `uv cache size` reports the size of the *whole* cache,
  not the reclaimable part. Summing it would turn "at least this much" into a
  promise; the user reads 10 GB and `uv cache prune` frees 400 MB. It goes to
  `metadata.size_bytes_upper_bound` and is reported as upside. The same
  applies to `docker-build-cache` **whenever `unused_for_days:` is set**:
  `docker system df` reports what an *unfiltered* prune frees, and docker
  cannot say in advance how much of that is unused for N days, so the figure
  becomes an upper bound rather than a claim.
- **Freed inside a VM.** See D7.

`metadata.size_basis` names how each figure was obtained, so the plan YAML is
self-documenting. `pnpm-store` reports neither a size nor an upper bound, and
says why: its store is hardlinked into the `node_modules` trees the
`node-modules` recipe already measures, so walking it would count those bytes
twice.

An inversion worth noting: `go-cache` and `mise-version` are the *blunt*
operations, and precisely because the whole directory goes, their measured
sizes are exact rather than upper bounds.

### D4. `go clean` is split into two opt-in halves, both off by default

Unlike every other recipe in this family, `go clean` does not remove what is
unreferenced — it removes everything. Following the `git-worktree merged:`
pattern, each half is a separate param defaulting to false, and a bare
`recipe "go-cache"` returns no items and emits a `progress.note` saying so.
Nobody can wipe a 3 GB module cache by accident.

They are separate items because their costs are not comparable:
`go clean -cache` costs CPU on the next build; `go clean -modcache` forces a
re-download of every module and breaks offline builds until it has run, which
the item's `reason` says verbatim.

### D5. `#verify` for a delegated item, and the probes that are not read-only

Two checks are always available: the tool is still on PATH, and the cache
directory still exists. Two tools offer a genuine non-mutating re-probe on top:

- `brew-cache` re-runs `brew cleanup --dry-run` and skips when it lists
  nothing. The dry run MUST carry the same `--prune` value as the command
  `#delete` will run, or the size reported is a size for a different
  operation.
- `mise-version` re-runs `mise ls --prunable --json`. **This is the most
  load-bearing re-check in the family**: "prunable" depends on which
  `.tool-versions` and `mise.toml` files mise has tracked, which is not the
  scenario's targets and which changes the moment the user opens an old
  project. A version that stops being prunable between plan and apply has
  been legitimately reclaimed, and `#verify` is what notices.

  The map is memoized on the class, mirroring `External::Docker.info`,
  because `ApplyCommand` builds a fresh recipe instance per item: a 30-item
  plan otherwise ran the query 30 times, each resolving every tracked
  config. Memoizing rather than narrowing to `mise ls --prunable <tool>` also
  gives one consistent view of "prunable" across a single apply, and avoids
  depending on a second response shape — with a tool argument mise returns a
  bare array rather than a map.

A probe that *fails* is not the same fact as a probe that came back empty,
and neither recipe may put something souji did not observe into the action
log. A failed `mise ls` reports "could not be read" rather than "a tracked
config now references it"; a `docker container inspect` that timed out, or
that failed against a daemon that is not answering, is reported as such
rather than as "container no longer present". `docker-container`'s listing
does the same on stderr, so an empty plan is distinguishable from a probe
that gave up.

`uv-cache`, `pnpm-store` and `go-cache` have no such probe, and each says so
in its own class documentation so that a thin `#verify` reads as a fact about
the tool rather than as an oversight.

`mise prune --dry-run` is deliberately unused: it rewrites mise's
tracked-configs state, so it is not read-only and has no place in
`souji plan`. Mapping souji's own `--dry-run` onto the tools' `--dry-run`
flags was also rejected — it would give the flag a second meaning and produce
log lines that look like deletions.

### D6. `docker-build-cache` is opaque, and the `buildx du` trap

Per-record pruning looks available and is not:

- `docker buildx du --format '{{json .}}'` lists per-record ids, but the vast
  majority report `"0B"` with the real bytes attributed to a handful. A few
  hundred plan rows summing to almost nothing, with the gigabytes hidden in
  five of them, is a fiction dressed as precision.
- There is no supported per-record delete. `docker buildx prune` takes no id,
  and removal cascades to a record's `Parents` — so a per-item `#delete`
  would remove other plan items as a side effect.

The size comes from `docker system df`'s `Build Cache` row `Reclaimable`
(8.709 GB on the measured machine). **Not** from `docker buildx du`'s trailing
`Reclaimable:` line, which counts records shared with live images and reported
13.59 GB — 4.9 GB more than a plain prune frees. `-a` is never passed.

### D7. The macOS diffdisk problem

On macOS the daemon runs inside a Linux VM, and pruning inside it does not
shrink the VM's sparse disk image. The space is reclaimed *inside* the VM and
the host's `df` does not move. `docker-image` had been overstating this way
since it shipped.

Detection is one memoized `docker info`: a Linux daemon on a non-Linux host,
which catches Rancher Desktop, Docker Desktop, colima and minikube alike and
is false on native Linux. Every item from all three docker recipes then
carries `metadata.host_space_unaffected`, `Plan#summary` keeps those bytes in
`vm_bytes` rather than `total_bytes`, the apply prompt gives them their own
line, and `souji plan` says it once per recipe on stderr.

A metadata-only or README-only answer would not have been enough: the byte
count is the whole value proposition, and it was wrong.

### D8. `scope_free!`, and why there is no second gate

Before this change 1 of 3 recipes ignored `target_roots`; after it, 8 of 13.
The README's containment bullet read as a global bound that would then not
apply to most items.

So the exception is declared rather than implied: `scope_free!` in the class
body, a `[scope-free]` marker in `souji recipes`, a line in the apply
confirmation, and — the part that keeps it honest —
`Scenario#run_plan` raises `ScopeViolationError` when a recipe emits a
synthetic URI without having declared it. The disclosure cannot drift from
what the recipe does.

The apply confirmation counts the items that carry
`metadata.scope_free`, read in `Plan#summary` alongside the other two
qualifiers. It deliberately does *not* re-derive the fact by matching the URI
shape: that would make the same claim true in two places for different
reasons, and leave the metadata key nothing reads.

**No scenario-level gate was added.** Typing `recipe "uv-cache"` in a file
you wrote is per-recipe consent already, and the marker plus the apply line
remove the possibility of surprise. A second `allow_scope_free!` declaration
would ask for consent twice for something the user named explicitly.

### D9. `Souji::External::*`, and what did not move onto it

Eight recipes now shell out. `Souji::External::Command` replaces bare
`Open3.capture3` for all of them, because `capture3` has two failure modes
that both land on the user at the worst moment:

- **No timeout.** `go clean -modcache` and `docker builder prune` run for
  minutes, and a tool that decides to prompt would hang `souji apply` *after*
  the user consented. Timeouts are constants, not params: a scenario setting
  30 seconds on `go clean -modcache` would manufacture spurious failures.
- **Deadlock.** A `wait_thr.join` with unread pipes hangs once the child
  fills a pipe buffer, which `docker buildx du` does on a few hundred records.
  Hence a drain thread per stream.
- **A timeout the child can outlive.** Signalling only the direct child is
  not enough: `docker builder prune` dispatches to the `docker-buildx` CLI
  plugin as a subprocess sharing our stdout, so the orphan keeps the write
  end open and a reader waits for an EOF that never comes. Measured on this
  machine, a 2-second timeout took the grandchild's full 20 seconds. Fixed by
  `pgroup: true` plus signalling the negative pid, and by bounding the reader
  wait afterwards so that even an unkillable holder cannot hang
  `souji apply` — a partial answer beats a hang, since the user has already
  consented by then.

Stdin is closed immediately so a prompt becomes EOF. Note that `popen3`
always hands the child a stdin pipe and an `in:` option does **not** displace
it — closing the pipe is what works, and a spec pins that down.

`NONINTERACTIVE_ENV` carries only variables that suppress prompting, colour
and background updates. `HOMEBREW_NO_INSTALL_FROM_API` looked like it
belonged and had to come out: it switches Homebrew to its local tap, which
moved the size `brew cleanup --dry-run` reported by 230 MB and could trigger
a tap clone slow enough to blow the probe timeout. **souji must observe the
tool the user has, not a differently configured one.**

`Souji::External::HumanSize` takes an explicit `base:` because the sources
disagree, and extracting it fixed a real bug: docker prints SI units, so `kB`
is 1000, and `docker_image.rb` was multiplying by 1024 — overstating every
image by about 7% at GB scale. Homebrew prints binary quantities behind
SI-looking labels and writes thousands separators into adjacent file counts.
A `:leading` mode reads docker's `"625kB (virtual 45.7MB)"`.

**`Souji::Git::Command` deliberately did not move.** Its `git -C <dir>` shape
and no-timeout assumption are load-bearing across `base_ref.rb`, `commit.rb`,
`worktree_list.rb` and `worktree_policy.rb`, and `fetch` already has its own
`BatchMode`/`ConnectTimeout` story. The asymmetry is intentional, and is
recorded so it does not read as an oversight.

### D10. `docker image prune -f` needed nothing

The runbook's line is already subsumed by `docker-image`, and covered better:
one item per image with its own size and its own re-verification that the
image is still present and still untagged. `docker-image` gained only the VM
metadata, the SI size fix and `scope_free!`.

### D11. Running containers can never be proposed

Three independent mechanisms, and the redundancy is the point:

1. the listing filters to `exited`, `created` and `dead`, and the result is
   filtered again in Ruby against `TERMINAL_STATES`, so a docker release with
   looser filter semantics still could not surface a live container;
2. `#verify` re-inspects `.State.Status` immediately before removal, which is
   what catches a `docker compose up` between plan and apply;
3. `docker rm` runs without `-f`, so even losing that race fails loudly
   rather than killing something that is working.

`-v` is never passed: removing a container is not consent to remove a
database's data directory. Reported sizes are the **writable layer only** —
docker's leading figure — because the virtual size is shared with the image
and is not freed. Reading the wrong one overstates a typical stopped
container by a factor of several hundred.

## Test plan

- `spec/unit/external/command_spec.rb` — the timeout kills a child, large
  output does not deadlock, a child reading stdin gets EOF rather than
  hanging, the non-interactive env reaches the child, and nothing in that env
  changes what a tool would decide to do.
- `spec/unit/external/human_size_spec.rb` — docker's SI, Homebrew's binary,
  the `(virtual ...)` suffix, the thousands separator, and every shape that
  must come back nil.
- `spec/unit/recipes/*_spec.rb` (7 files, untagged and fully stubbed through
  `Souji::External::Command.run`, which is the single seam the shared layer
  buys). Per recipe: the class declarations, the synthetic URI, the exact
  `argv`, `size_bytes` versus `size_bytes_upper_bound`, every `#verify`
  branch, `#delete` on success, failure and timeout — and a **read-only
  assertion** that `#enumerate` never invokes a mutating command.
- `spec/integration/recipes/*_spec.rb` (7 files, tag-gated per tool) run the
  real probes against the real tool and assert structure and read-only-ness.
  They never call `#delete`, which would prune the developer's own caches.
- `spec/support/tool_fixtures.rb` holds output captured verbatim from a real
  machine. Handwritten fixtures would have hidden every trap that mattered:
  `kB` versus `KB`, `1,707 files`, `(virtual ...)`, mise's WARN lines on
  stderr, a mise tool name containing a colon and a slash
  (`aqua:open-policy-agent/opa`), and the `buildx du` Reclaimable overcount.
- `spec/unit/plan_spec.rb` and `spec/unit/commands/apply_prompt_spec.rb` —
  the three kinds of byte, and that an ordinary plan still renders with no
  qualifiers at all.
- `spec/unit/scenario_spec.rb` — a recipe emitting a synthetic URI without
  `scope_free!` is refused.
- `spec/integration/recipe_contract_spec.rb` records which recipes take the
  containment exception, so adding one is a deliberate edit.
- Coverage note: all new coverage comes from untagged stubbed unit specs, so
  the ≥80% line gate holds in a CI without any of these tools installed.
