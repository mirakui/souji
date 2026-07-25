# frozen_string_literal: true

require "fileutils"
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
    # intentionally has no ensure_scenario_dir!).
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
        # recipe list.
        #
        # 1. Declare the directories souji may look at. Nothing outside a
        #    declared target can be enumerated or deleted.
        #
        # target File.expand_path("~/work")
        #
        # 2. Declare the recipes to run.
        #
        # recipe "git-worktree"        # abandoned git worktrees under the targets
        # recipe "terraform-provider"  # cached providers that no lockfile references
        # recipe "docker-image"        # dangling docker images (path-independent)
        #
        # Recipes take keyword params, e.g. only prune older docker layers:
        #
        # recipe "docker-image", older_than_days: 30
        #
        # 3. Narrow a recipe to a subset of the targets with with_targets:
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
        existed = File.exist?(path)
        return report_kept(path) if existed && !force

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, TEMPLATE)
        report_written(path, existed: existed)
        ExitCodes::SUCCESS
      rescue SystemCallError, IOError => e
        @stderr.puts("[souji] init failed: #{e.class}: #{e.message}")
        ExitCodes::UNEXPECTED
      end

      private

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
