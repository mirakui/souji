# frozen_string_literal: true

require "fileutils"
require "securerandom"
require_relative "../exit_codes"
require_relative "../paths"

module Souji
  module Commands
    # Orchestrates `souji init`: provisions the scenario directory and
    # writes the `default.rb` scenario template that `souji plan` (with no
    # argument) reads.
    #
    # The template is entirely commented out, so a freshly initialized
    # scenario is a no-op: `souji plan` right after `souji init` produces
    # an empty plan and can never propose deleting anything the user did
    # not opt into.
    #
    # This is the ONE code path allowed to create the scenario directory —
    # everywhere else it is the user's to provision (Souji::Paths
    # intentionally has no ensure_scenario_dir!). Nothing outside the
    # scenario directory is touched.
    #
    # Two safety rules bound what init may clobber:
    #
    # - A destination that is not a regular file (symlink, directory, FIFO,
    #   ...) is refused with or without --force: --force means "overwrite
    #   the regular file I edited", not "destroy whatever is in the way".
    # - The write is atomic (temp file in the same directory, fsync,
    #   rename) so a crash mid-write can never leave a truncated scenario
    #   that would make `souji plan` die with a SyntaxError.
    class InitCommand
      # Kept strictly ASCII: scenario files are read with File.read and
      # evaluated, so on a machine whose default external encoding is
      # US-ASCII (no LANG set) any non-ASCII byte here - even inside a
      # comment - would make the scenario unloadable.
      TEMPLATE = <<~SCENARIO
        # souji default scenario
        #
        # `souji plan` with no argument reads this file (it is the same as
        # `souji plan default`). Everything below is commented out, so as
        # generated this scenario proposes nothing: uncomment what you want.
        #
        # This file is plain Ruby: loops, constants and helpers all work. The
        # DSL below just adds vocabulary. Run `souji recipes` for the live
        # recipe list and the options each one accepts.
        #
        # 1. Declare the directories souji may look at. Nothing outside a
        #    declared target can be enumerated or deleted, and the recipes
        #    below need at least one target declared.
        #
        # target File.expand_path("~/work")
        #
        # 2. Declare the recipes to run. Options are keyword arguments and
        #    are all optional; the values below are examples. Passing an
        #    option a recipe does not declare is an error, so `souji plan`
        #    catches a typo before it scans anything.
        #
        # git-worktree -- worktrees under the targets that are finished
        #   with: the ones git has flagged prunable, plus, if you ask for
        #   them, the ones whose branch is already merged upstream.
        #
        #   merged:       also propose worktrees whose branch is already
        #                 merged into the base ref (default: false).
        #                 Worktrees that are locked or hold uncommitted
        #                 changes are never proposed.
        #   merged_into:  base ref for that check (default: origin/HEAD,
        #                 falling back to origin/main or origin/master)
        #   fetch:        refresh the base ref from its remote before
        #                 judging. The only network access `souji plan`
        #                 ever makes (default: false)
        #   older_than_days:  also propose worktrees whose last commit is
        #                 at least this old, merged or not (default: no
        #                 age check). A detached HEAD no ref points at is
        #                 never proposed: deleting it would lose the work.
        #
        # recipe "git-worktree"
        # recipe "git-worktree", merged: true
        # recipe "git-worktree", merged: true, fetch: true
        # recipe "git-worktree", merged: true, older_than_days: 90
        #
        # terraform-provider -- cached provider versions that no
        #   .terraform.lock.hcl under the targets references.
        #
        #   plugin_cache_dir:  provider cache to prune (default:
        #                      $TF_PLUGIN_CACHE_DIR, else
        #                      ~/.terraform.d/plugin-cache)
        #
        # recipe "terraform-provider"
        # recipe "terraform-provider", plugin_cache_dir: "~/.terraform.d/plugin-cache"
        #
        # terraform-dir -- the regenerable contents of a local
        #   .terraform/: providers/, modules/, and anything else
        #   `terraform init` rebuilds. The two entries init does NOT
        #   rebuild -- `environment`, which records the selected
        #   workspace, and the cached backend config -- are never
        #   proposed, so a cleanup cannot point your next apply at the
        #   wrong workspace. A root is only proposed when it has *.tf
        #   files AND a .terraform.lock.hcl (without the lock, re-init
        #   could silently change provider versions), and never while an
        #   apply might be in flight: a held state lock, a leftover
        #   errored.tfstate, or a saved plan file.
        #
        #   older_than_days:  only propose contents whose last
        #                     `terraform init` is at least this old
        #                     (default: no age filter)
        #
        # recipe "terraform-dir"
        # recipe "terraform-dir", older_than_days: 90
        #
        # node-modules -- node_modules/ trees a lockfiled install can
        #   rebuild. Requires a sibling package.json that parses and a
        #   sibling lockfile: an install without a lockfile re-resolves
        #   semver ranges, so what comes back is not what was deleted.
        #   In a monorepo only the root holding the lockfile is proposed.
        #
        #   older_than_days:  only propose trees whose last install is at
        #                     least this old (default: no age filter)
        #
        # recipe "node-modules"
        # recipe "node-modules", older_than_days: 90
        #
        # python-venv -- virtualenvs a sibling manifest can recreate. A
        #   venv is recognised by its pyvenv.cfg and interpreter, not by
        #   its name, and needs uv.lock / poetry.lock / Pipfile.lock /
        #   requirements.txt / pyproject.toml in its immediate parent. The
        #   virtualenv souji is running inside is never proposed, and
        #   conda environments never match.
        #
        #   older_than_days:  only propose venvs whose last install is at
        #                     least this old (default: no age filter)
        #
        # recipe "python-venv"
        # recipe "python-venv", older_than_days: 90
        #
        # docker-image -- dangling images (no tag, no container ancestry).
        #   Path-independent: it ignores the targets entirely.
        #
        #   older_than_days:  only propose images created at least this many
        #                     days ago (default: no age filter)
        #
        # recipe "docker-image"
        # recipe "docker-image", older_than_days: 30
        #
        # For terraform-dir, node-modules and python-venv, older_than_days
        # is measured from the artifact's own last generation -- the last
        # `terraform init`, the package manager's install receipt, the
        # venv's site-packages -- not from when you last edited the
        # project. A repository you touched today can still hold a
        # provider cache from last year, and that cache is the point.
        #
        # Worktree items and these three nest, because a worktree can hold
        # a .terraform/ or a node_modules/. Declare git-worktree first: the
        # worktree then goes to the trash as one unit and the nested items
        # report "already removed" when apply re-verifies them.
        #
        # docker-container -- containers that have stopped for good:
        #   exited, created but never started, or dead. One item each,
        #   with its own size. Running containers cannot be proposed:
        #   the listing is filtered to terminal states and filtered
        #   again in souji, the state is re-checked immediately before
        #   removal, and `docker rm` is run without -f so even losing
        #   that race fails instead of killing something. -v is never
        #   passed either: a container's volumes are not ours.
        #
        #   older_than_days:  only propose containers created at least
        #                     this many days ago (default: no age filter)
        #
        # recipe "docker-container"
        # recipe "docker-container", older_than_days: 30
        #
        # docker-build-cache -- the reclaimable part of docker's buildkit
        #   cache, via `docker builder prune -f`. Never -a, so cache
        #   still in use is left alone. One opaque item: docker has no
        #   supported per-record delete.
        #
        #   unused_for_days:  only prune records unused for at least this
        #                     many days (default: all reclaimable)
        #
        # recipe "docker-build-cache"
        # recipe "docker-build-cache", unused_for_days: 30
        #
        # On macOS the docker daemon runs inside a Linux VM, and pruning
        # inside it does not shrink the VM's disk image -- the space is
        # freed in the VM and your `df` does not move. souji says so
        # while planning and keeps those bytes out of the host total.
        #
        # 2b. Recipes that ask a tool to prune its own cache. These are
        #     "scope-free": they act on the tool's own store, so the
        #     targets above do not bound them -- what bounds them is the
        #     tool's idea of what is unreferenced. souji never deletes
        #     these files itself, and nothing goes to the trash, so every
        #     one of these deletions is irreversible. `souji recipes`
        #     marks them, and the plan records the exact command that
        #     will run.
        #
        # uv-cache -- `uv cache prune` drops the objects in uv's cache
        #   that nothing references. No options. The plan cannot promise a
        #   figure here (uv reports only the whole cache size), so it
        #   offers that as an upper bound instead.
        #
        # recipe "uv-cache"
        #
        # pnpm-store -- `pnpm store prune` removes the packages in pnpm's
        #   store that no project references. No options, and no size at
        #   all: the store is hardlinked into the node_modules trees that
        #   node-modules already counts.
        #
        # recipe "pnpm-store"
        #
        # brew-cache -- `brew cleanup` removes outdated downloads. souji
        #   reads `--dry-run` first, so this one reports a real size and
        #   lists what it saw.
        #
        #   prune_days:  remove downloads older than this many days
        #                instead of all of them (default: all)
        #
        # recipe "brew-cache"
        # recipe "brew-cache", prune_days: 30
        #
        # mise-version -- tool versions no tracked mise config references,
        #   one item per version, each removed with `mise uninstall`.
        #   Note that "referenced" means referenced by a config mise has
        #   tracked, which is not the same as your targets: open an old
        #   project and a version stops being prunable.
        #
        #   tools:  only propose versions of these tools (default: every
        #           prunable tool)
        #
        # recipe "mise-version"
        # recipe "mise-version", tools: ["awscli", "terraform"]
        #
        # go-cache -- `go clean`. Unlike the recipes above, this does not
        #   remove what is unreferenced, it removes EVERYTHING, so each
        #   half is opt-in and a bare `recipe "go-cache"` proposes
        #   nothing.
        #
        #   build_cache:  wipe GOCACHE; costs only a rebuild
        #                 (default: false)
        #   mod_cache:    wipe GOMODCACHE; forces a re-download of every
        #                 module and breaks offline builds until it has
        #                 run (default: false)
        #
        # recipe "go-cache", build_cache: true
        # recipe "go-cache", build_cache: true, mod_cache: true
        #
        # 3. Narrow a recipe to a subset of the targets with with_targets.
        #    The paths must sit inside an already-declared target -- this
        #    narrows the scope, it cannot create one.
        #
        # with_targets "~/work/infra" do
        #   recipe "terraform-provider"
        # end
        #
        # Then review and apply:
        #
        #   souji plan              # writes ~/.cache/souji/default.soujiplan
        #   souji apply --dry-run   # preview, delete nothing
        #   souji apply             # confirm, then delete
      SCENARIO

      def initialize(stdout: $stdout, stderr: $stderr)
        @stdout = stdout
        @stderr = stderr
      end

      # Returns a Souji::ExitCodes::* value.
      def call(force: false)
        path = Paths.default_scenario_path
        existing = lstat_or_nil(path)
        return refuse_non_regular(path, existing) if existing && !existing.file?
        return report_kept(path) if existing && !force

        FileUtils.mkdir_p(File.dirname(path))
        write_atomically(path, TEMPLATE)
        report_written(path, existed: !existing.nil?)
        ExitCodes::SUCCESS
      rescue SystemCallError, IOError => e
        @stderr.puts("[souji] init failed: #{e.class}: #{e.message}")
        ExitCodes::UNEXPECTED
      end

      private

      # File.lstat rather than File.stat: a symlink must be seen as a
      # symlink, not as whatever it points at.
      def lstat_or_nil(path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end

      # Write via a temp file in the same directory + rename(2), so a
      # reader never observes a partially-written scenario. Failures before
      # the rename leave the destination untouched.
      def write_atomically(path, content)
        tmp = File.join(File.dirname(path),
                        ".#{File.basename(path)}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}")
        begin
          File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |f|
            f.write(content)
            f.flush
            f.fsync
          end
          File.rename(tmp, path)
        rescue StandardError
          FileUtils.rm_f(tmp)
          raise
        end
      end

      def refuse_non_regular(path, stat)
        @stderr.puts(
          "[souji] usage error: destination is not a regular file: " \
          "#{path} is a #{describe_ftype(stat)}"
        )
        @stderr.puts("[souji] inspect and remove it yourself; --force does not override this")
        ExitCodes::USAGE_ERROR
      end

      def describe_ftype(stat)
        stat.ftype == "link" ? "symbolic link" : stat.ftype
      end

      def report_kept(path)
        @stdout.puts("#{path} already exists (pass --force to overwrite)")
        ExitCodes::SUCCESS
      end

      def report_written(path, existed:)
        @stdout.puts("#{existed ? "overwrote" : "created"} #{path}")
        @stderr.puts("[souji] edit it, then run `souji plan` to see what would be deleted")
      end
    end
  end
end
