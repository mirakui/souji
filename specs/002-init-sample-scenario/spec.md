# Feature Specification: `souji init` — Generate a Sample Scenario

**Feature Branch**: `002-init-sample-scenario`

**Created**: 2026-05-22

**Status**: Draft

**Input**: User description: "`souji init` でサンプルの scenario を生成するようにしたい"

## Clarifications

### Session 2026-05-22

- Q: `souji init` で `<name>` を省略したときのデフォルト bare name は？ → A: `default` を採用する。XDG 慣習で「未指定時のリソース」を示す中立的な名前であり、`sample`（ひな型を強調）や `weekly`（quickstart 既存例との一貫性）よりも、コマンドのデフォルト挙動として意図を素直に表す。`quickstart.md` は本機能の実装と同時に `default` を使う形に更新する。
- Q: 生成されるサンプルが参照する recipe の範囲は？ → A: `git-worktree` のみの最小構成にする。`git` は quickstart で必須前提条件として明記されているため、初回 `souji plan default` 実行時に recipe スキップの警告が一切発生せず、出力がクリーン。ユーザーが他の組み込み recipe を試したい場合は、生成ファイル末尾のコメントで `recipe "terraform-provider"` / `recipe "docker-image"` の追加方法を案内する。
- Q: `souji init <name>` の `<name>` 引数に許容する文字種は？ → A: 厳格な ASCII allowlist 正規表現 `^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$` で検証する。先頭文字は英数字またはアンダースコア、以降は英数字 / アンダースコア / ピリオド / ハイフン、最大長 64 文字。これにより空文字・`.`・`..`・`/` を含む値・`~` 始まり・`.rb` 終わり・改行・空白・シェル特殊文字 (`*` `?` `$` 等)・Unicode 制御文字をまとめて拒否でき、bare name から filesystem basename への変換が予測可能になる。`Paths.path_shaped?` による既存の拒否条件はこの allowlist に包含される。日本語等のマルチバイト文字はサポート対象外（必要なら `<XDG_CONFIG_HOME>/souji/scenario/<日本語>.rb` をユーザーが直接編集すれば良く、CLI からは作らない）。
- Q: destination に既存エントリが通常ファイル以外（symlink / ディレクトリ / 非通常ファイル）の場合の挙動は？ → A: `--force` の有無に関わらず常に拒否し usage error (exit 2)。`--force` の責務を「ユーザー編集された通常ファイルの上書き」に限定し、意図的に置かれた symlink（dotfiles 管理など）や誤って作られたディレクトリを破壊するリスクを排除する。stderr には「destination is not a regular file」相当の診断と該当パスを出す。Constitution Principle V（Safety by Default）と整合。
- Q: ファイル書き込みのアトミック性は要件として保証するか？ → A: 必須化する。同一ディレクトリの一時ファイル（例: `default.rb.tmp.<pid>.<rand>`）にサンプル内容を書き出して `fsync` し、`File.rename` で destination にアトミックに置換する。POSIX `rename(2)` の同一 filesystem 内アトミック保証により、書き込み途中での SIGKILL / `ENOSPC` / 電源断でも destination は「書き込み前」か「完全な新内容」のいずれかに必ず保たれ、半端な scenario ファイルが残って `souji plan default` を SyntaxError で失敗させる事故を排除できる。エラー時は一時ファイルを片付けてから exit する。

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
  MUST name the unwritable path; no partial file is left on disk (FR-011's
  cleanup-on-failure invariant covers this).
- **Disk full mid-write**: The temporary file write fails with `ENOSPC` after
  the directory has been created (or already existed) but before the rename.
  Per FR-011, Souji MUST remove the temporary file, leave the destination
  untouched (whether or not it already existed), exit with a non-zero status,
  and write a diagnostic naming the destination path on stderr.
- **Bare name not in the allowlist**: The user passes an argument that fails the
  FR-004 allowlist — empty string, `.`, `..`, a value containing `/`, a value
  starting with `~`, a value ending with `.rb`, whitespace, shell metacharacters
  (`*`, `?`, `$`, …), control characters, or non-ASCII Unicode (e.g. `週次`).
  `souji init` MUST reject all such inputs with a usage error (exit code 2). The
  command is defined to write into the XDG scenario directory by bare name only;
  users who want a filename outside the allowlist (e.g., Japanese-named
  scenarios) are expected to author the file directly with an editor.
- **Generated file references recipes that are not installed at apply time**: The
  active recipe in the sample (`git-worktree`) requires `git`, which is already a
  documented Souji prerequisite, so a stock workstation produces no recipe-skip
  warnings on the first `souji plan default`. If the user later uncomments the
  `terraform-provider` or `docker-image` lines (per FR-008) on a workstation
  missing those external commands, plan will skip them with a stderr warning per
  FR-020 of the parent spec; the inline comment in the generated file explains
  this so a confused user is not surprised.
- **`$XDG_CONFIG_HOME` is set to a non-default location**: The destination path is
  derived from `$XDG_CONFIG_HOME` (with the documented fallback to `~/.config`),
  so a custom value MUST be honoured. Verified by running `XDG_CONFIG_HOME=/tmp/x
  souji init` and confirming the file lands under `/tmp/x/souji/scenario/`.
- **Re-running `souji init --force` against a file the user did not create with
  `init`**: There is no marker distinguishing a sample-generated scenario from a
  hand-authored one. `--force` MUST overwrite regardless of who wrote the file,
  provided the existing entry is a regular file (FR-006). The safety affordance
  is the absence of `--force`, not file-origin detection.
- **Destination is a symlink or directory**: The destination path exists but is
  a symbolic link (e.g., user manages dotfiles via stow) or a directory (e.g.,
  user previously ran `mkdir scenario.rb` by mistake). Per FR-005a, `souji init`
  MUST refuse to write in both cases — with OR without `--force` — and exit
  with usage error. The user inspects and removes the entry manually before
  retrying `souji init`.

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
  naming the bare scenario name to generate. When omitted, Souji MUST use the
  documented default bare name `default`. The resolved filename MUST be
  `<name>.rb` under the scenario directory.
- **FR-004**: `souji init` MUST validate `<name>` against the ASCII allowlist
  regex `\A[A-Za-z0-9_][A-Za-z0-9_.\-]{0,63}\z` (see Clarifications §3). The
  first character MUST be alphanumeric or underscore; subsequent characters MAY
  additionally include `.` and `-`; total length MUST be 1–64 characters. Any
  argument that fails this check — including the empty string, `.`, `..`,
  values that would have been rejected by `Paths.path_shaped?` (contain `/`,
  start with `~`, or end with `.rb`), whitespace, shell metacharacters, and
  non-ASCII characters — MUST cause Souji to exit with usage error (exit code
  2) and stderr MUST include the offending value (quoted) and a short
  description of the allowed character set.
- **FR-005**: When the destination path already exists as a regular file,
  `souji init` MUST NOT overwrite it. Souji MUST exit with usage error (exit
  code 2) and stderr MUST include the existing path and the literal hint
  `--force` so the user knows how to override.
- **FR-005a**: When the destination path already exists but is NOT a regular
  file (symbolic link, directory, FIFO, socket, device file, or any other
  non-regular filesystem entry), `souji init` MUST refuse to write — with OR
  without `--force` (see Clarifications §4). Souji MUST exit with usage error
  (exit code 2) and stderr MUST include the existing path and a short
  description of why it was rejected (e.g., "destination is not a regular
  file: <path> is a directory"). `--force` is not a remediation for this case;
  the user is expected to inspect and remove the non-regular entry manually.
- **FR-006**: `souji init --force` MUST overwrite the destination file when
  (and only when) the existing entry is a regular file, subject to filesystem
  permissions. On successful overwrite Souji MUST exit with success and report
  the overwritten path on stdout. `--force` MUST NOT escalate the FR-005a
  refusal — non-regular destinations remain rejected.
- **FR-007**: The generated file MUST be a syntactically valid scenario that loads
  cleanly under the existing scenario loader (`Souji::Scenario.from_file`). It
  MUST reference at least one `target` and exactly one active `recipe` call:
  `recipe "git-worktree"`. `git-worktree` is chosen because `git` is a Souji
  prerequisite (see `quickstart.md`), so the sample runs cleanly with no
  recipe-skip warnings on every supported workstation (see Clarifications §2).
  The other built-in recipes (`terraform-provider`, `docker-image`) MUST be
  referenced only as commented-out lines accompanied by a comment explaining
  how to enable them.
- **FR-008**: The generated file MUST contain Ruby comments that name each DSL
  construct it uses (at minimum `target` and `recipe`), show the commented-out
  invocations for the other built-in recipes per FR-007 with a one-line note
  about how skipping behaves when an external command is missing (FR-020 of the
  parent spec), so a reader new to Souji can edit the file without consulting
  external documentation.
- **FR-009**: On success, `souji init` MUST print the absolute path of the
  generated (or overwritten) file to stdout and exit with success (exit code 0).
  On any failure (existing file without `--force`, invalid `<name>`, unwritable
  destination), Souji MUST exit with a non-zero status and write a diagnostic on
  stderr that names the problematic path.
- **FR-010**: `souji init` MUST NOT modify any file or directory other than the
  destination scenario file and the scenario directory itself. In particular it
  MUST NOT touch `$XDG_CACHE_HOME/souji/`, `$XDG_STATE_HOME/souji/log/`, or any
  user file outside the scenario directory.
- **FR-011**: `souji init` MUST write the destination file atomically (see
  Clarifications §5). Souji MUST first write the sample content to a temporary
  file inside the same destination directory, ensure the bytes are durably
  flushed (`fsync` or equivalent), and then atomically replace the destination
  via `rename(2)`. At no point during a `souji init` invocation MAY a reader
  observe a partially-written destination: the destination is either absent /
  unchanged, or it is the complete new content. If any step before the rename
  fails (write error, `ENOSPC`, etc.), Souji MUST remove the temporary file
  before exiting with a non-zero status.

### Key Entities

- **Sample scenario template**: The Ruby source text that `souji init` writes to
  disk. Ships as part of the Souji distribution. Contains placeholder `target`
  and `recipe` calls plus explanatory comments. Bytewise identical across all
  invocations of the same Souji version, so two `souji init --force` runs back to
  back produce identical files.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A first-time user can go from a fresh machine to a generated plan
  in exactly two commands (`souji init && souji plan default`), with no manual
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
- **SC-006**: When `souji init` is interrupted mid-write (simulated via
  `ENOSPC`, SIGKILL, or a mocked I/O error before the rename), the destination
  path is either absent or byte-identical to its pre-invocation state in 100%
  of test runs. No temporary `*.tmp*` file is left in the scenario directory
  after the process exits.

## Assumptions

- The `souji` CLI process has filesystem permission to create
  `$XDG_CONFIG_HOME/souji/scenario/` and to write a regular file inside it. Cases
  where this is false (read-only filesystem, restrictive `umask`, SELinux/macOS
  TCC denial) are reported as errors per FR-009; no privilege escalation,
  retry-with-sudo, or alternate-location fallback is in scope.
- The default bare name chosen for `souji init` when `<name>` is omitted is
  `default` (see Clarifications §1). This is a deliberate departure from the
  `weekly.rb` example in `quickstart.md`. `default` is a neutral XDG-flavoured
  name that simply identifies "the scenario you get when you do not name one",
  without implying a specific cadence (weekly) or status (sample). The quickstart
  will be updated alongside this feature so the two stay in sync.
- The generated sample references a single `target` pointing at `~/work` and a
  single active recipe call `recipe "git-worktree"` (see Clarifications §2 and
  FR-007). The other two built-in recipes (`terraform-provider`, `docker-image`)
  appear only as commented-out lines so the first `souji plan default` produces
  no recipe-skip warnings on a stock workstation while still discoverably
  documenting the rest of the recipe surface area.
- `souji init` is an addition to the CLI surface, not a modification of any
  existing subcommand. The existing rule that no other Souji code path may create
  `$XDG_CONFIG_HOME/souji/scenario/` (parent-spec FR-007b) continues to hold for
  every command other than `init`.
- The generated file is plain UTF-8 Ruby source with no shebang and no execute
  bit; it is consumed by `souji plan` via `instance_eval`, not run as a script.
