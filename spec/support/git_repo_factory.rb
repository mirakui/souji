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

      # Give `repo` a bare "origin" on the local filesystem with `main`
      # pushed and refs/remotes/origin/HEAD pointed at it. Merge-status
      # specs need a real remote-tracking ref, but not a real network.
      # Returns the bare repository's path.
      def add_remote_with_main(repo:, remote_path: "#{repo}-origin.git")
        sh!("git", "init", "-q", "--bare", "-b", "main", remote_path)
        sh!("git", "-C", repo, "remote", "add", "origin", remote_path)
        sh!("git", "-C", repo, "push", "-q", "origin", "main")
        sh!("git", "-C", repo, "remote", "set-head", "origin", "main")
        remote_path
      end

      # Commit inside a linked worktree so its branch actually diverges
      # from the branch it was cut from. The default filename is derived
      # from the worktree so that sibling worktrees of the same repo do not
      # stage identical content (which would make the commit a no-op once
      # the first of them is merged).
      #
      # `days_ago:` backdates the commit. GIT_COMMITTER_DATE rejects
      # relative dates ("120 days ago" is a fatal error), so the timestamp
      # is computed here and handed over absolute.
      def commit_in_worktree(wt_path, message: "work", file: nil, days_ago: nil)
        file ||= "WORK-#{File.basename(wt_path)}"
        File.write(File.join(wt_path, file), "#{message}\n")
        sh!("git", "-C", wt_path, "add", file)
        sh!("git", "-C", wt_path, "commit", "-q", "-m", message, env: commit_date_env(days_ago))
        wt_path
      end

      def commit_date_env(days_ago)
        return {} unless days_ago

        stamp = (Time.now - (days_ago * 86_400)).strftime("%Y-%m-%dT%H:%M:%S%z")
        { "GIT_AUTHOR_DATE" => stamp, "GIT_COMMITTER_DATE" => stamp }
      end

      # A worktree with no branch of its own. Its HEAD is only kept alive
      # by whatever `commit` resolves to.
      def add_detached_worktree(repo:, wt_path:, commit: "HEAD")
        FileUtils.mkdir_p(File.dirname(wt_path))
        sh!("git", "-C", repo, "worktree", "add", "-q", "--detach", wt_path, commit)
        wt_path
      end

      # Merge `branch` into the repo's default branch and push, so the
      # branch tip becomes an ancestor of origin/<default_branch>.
      def merge_branch_into_default!(repo:, branch:, default_branch: "main")
        sh!("git", "-C", repo, "merge", "-q", "--no-ff", "-m", "merge #{branch}", branch)
        sh!("git", "-C", repo, "push", "-q", "origin", default_branch)
      end

      # Modify a tracked file so `git status --porcelain` reports a change.
      def dirty_worktree!(wt_path, file: "README")
        File.write(File.join(wt_path, file), "dirty\n")
        wt_path
      end

      def add_untracked_file!(wt_path, file: "scratch.txt")
        File.write(File.join(wt_path, file), "untracked\n")
        wt_path
      end

      def sha_of(repo:, rev: "HEAD")
        `git -C #{repo.shellescape} rev-parse #{rev.shellescape}`.strip
      end

      # Rewind a remote-tracking ref to an earlier commit, simulating a
      # clone that has not fetched since the branch moved on.
      def stale_tracking_ref!(repo:, commit:, ref: "refs/remotes/origin/main")
        sh!("git", "-C", repo, "update-ref", ref, commit)
      end

      def lock_worktree!(repo:, wt_path:)
        sh!("git", "-C", repo, "worktree", "lock", wt_path)
        wt_path
      end

      def sh!(*argv, env: {})
        result = system(env, *argv, out: File::NULL, err: File::NULL)
        raise "command failed: #{argv.join(" ")}" unless result
      end
    end
  end
end

RSpec.configure do |config|
  config.include Souji::SpecSupport::GitRepoFactory, :git
end
