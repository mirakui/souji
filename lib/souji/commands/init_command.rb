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
        # git-worktree -- abandoned git worktrees under the targets.
        #   Takes no options.
        #
        # recipe "git-worktree"
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
        # docker-image -- dangling images (no tag, no container ancestry).
        #   Path-independent: it ignores the targets entirely.
        #
        #   older_than_days:  only propose images created at least this many
        #                     days ago (default: no age filter)
        #
        # recipe "docker-image"
        # recipe "docker-image", older_than_days: 30
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
