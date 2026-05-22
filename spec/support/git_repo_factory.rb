# frozen_string_literal: true

require "fileutils"
require "shellwords"

module Souji
  module SpecSupport
    # Builds real git repositories with worktrees attached for integration
    # tests of Souji::Recipes::GitWorktree. Backed by actual `git`
    # subprocesses to honor Constitution Principle IV (integration tests
    # exercise real boundaries).
    module GitRepoFactory
      # Build a bare working repo at `path` with the given commits. Returns
      # the path.
      def build_git_repo(path)
        FileUtils.mkdir_p(path)
        sh!("git", "-C", path, "init", "-q", "-b", "main")
        sh!("git", "-C", path, "config", "user.email", "spec@example.com")
        sh!("git", "-C", path, "config", "user.name", "Spec")
        # Ensure the spec is independent of the developer's global
        # gpg-sign / signing-key configuration.
        sh!("git", "-C", path, "config", "commit.gpgsign", "false")
        sh!("git", "-C", path, "config", "tag.gpgsign", "false")
        File.write(File.join(path, "README"), "ok\n")
        sh!("git", "-C", path, "add", "README")
        sh!("git", "-C", path, "commit", "-q", "-m", "init")
        path
      end

      # Add a worktree at `wt_path` pointed at a new branch `branch_name`
      # off HEAD.
      def add_worktree(repo:, wt_path:, branch_name:)
        FileUtils.mkdir_p(File.dirname(wt_path))
        sh!("git", "-C", repo, "worktree", "add", "-b", branch_name, wt_path)
        wt_path
      end

      # Make the worktree prunable from git's perspective by deleting the
      # actual worktree directory on disk while leaving the registration
      # behind in .git/worktrees/. `git worktree list --porcelain` will
      # then report this entry with `prunable` set.
      def make_worktree_prunable!(wt_path)
        FileUtils.rm_rf(wt_path)
      end

      def sh!(*argv)
        result = system(*argv, out: File::NULL, err: File::NULL)
        raise "command failed: #{argv.join(" ")}" unless result
      end
    end
  end
end

RSpec.configure do |config|
  config.include Souji::SpecSupport::GitRepoFactory, :git
end
