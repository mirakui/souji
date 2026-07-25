# frozen_string_literal: true

require "find"
require_relative "../recipe"
require_relative "../plan_item"
require_relative "../errors"
require_relative "../trash"
require_relative "../git/command"
require_relative "../git/registration"
require_relative "../git/worktree_list"
require_relative "../git/worktree_policy"

module Souji
  module Recipes
    # Identifies git worktrees that are no longer doing any work and
    # proposes them for deletion.
    #
    # Three ways a worktree stops doing work:
    #
    # 1. git itself flagged it `prunable` — the directory has vanished and
    #    only the registration is left. Always detected.
    # 2. Its branch is already contained in the repository's base ref
    #    (`origin/main` and friends): the work shipped. Opt-in via
    #    `merged: true`.
    # 3. Nothing has been committed on it for `older_than_days:` days.
    #    Opt-in, and independent of (2) — an abandoned spike is worth
    #    reclaiming whether or not it ever merged.
    #
    # `Souji::Git::WorktreePolicy` owns those rules, because `#verify` has
    # to re-apply exactly the same ones at apply time. This class handles
    # discovery, plan items, and deletion.
    #
    # Discovery walks each target_root for `.git` directories, then asks
    # each repository `git worktree list --porcelain`. A repository may
    # register worktrees anywhere on disk; only the ones living under a
    # declared target are this scenario's business.
    class GitWorktree < Souji::Recipe
      recipe_name "git-worktree"
      required_external_commands "git"
      description "Remove abandoned git worktrees (prunable, already merged, or long untouched)"
      param :merged, "Also propose worktrees whose branch is already merged into the base ref (default: false)"
      param :merged_into,
            "Base ref for the merged check (default: origin/HEAD, falling back to origin/main or origin/master)"
      param :fetch, "Refresh the base ref from its remote before the merged check (default: false)"
      param :older_than_days,
            "Also propose worktrees whose last commit is at least this many days old (default: no age check)"

      # Directories that never hold a repository worth scanning but do hold
      # enough files to dominate the walk.
      SKIP_DIRS = %w[node_modules .terraform .venv vendor bundle].freeze

      def enumerate(target_roots, params)
        roots = target_roots.map { |root| File.expand_path(root) }
        target_roots
          .flat_map { |root| find_git_repos(root) }
          .uniq
          .sort
          .flat_map { |repo| enumerate_repo(repo, params) }
          .select { |item| within_any?(item.path, roots) }
      end

      def verify(plan_item)
        repo = owning_repo(plan_item)
        return [:skip, "owning git repository no longer exists"] unless repo

        entry = Souji::Git::WorktreeList.for(repo).find(plan_item.path)
        return [:skip, "worktree no longer registered with git"] unless entry

        policy_for(repo, recheck_options(plan_item)).recheck(entry, plan_item.metadata["detection"])
      end

      def delete(plan_item)
        repo = owning_repo(plan_item)
        return [:failed, "owning git repository missing"] unless repo

        if Dir.exist?(plan_item.path)
          delete_worktree_directory(repo, plan_item.path)
        else
          delete_registration(repo, plan_item.path)
        end
      end

      private

      def within_any?(path, roots)
        normalized = File.expand_path(path)
        roots.any? { |root| normalized == root || normalized.start_with?("#{root}/") }
      end

      def find_git_repos(root)
        return [] unless Dir.exist?(root)

        repos = []
        Find.find(root) do |path|
          next unless File.directory?(path)

          case File.basename(path)
          when *SKIP_DIRS then Find.prune
          when ".git"
            repo = File.dirname(path) # `path` is the .git directory
            progress.scanning(repo)
            repos << repo
            Find.prune
          end
        rescue Errno::EACCES, Errno::ENOENT
          Find.prune
        end
        repos
      end

      def enumerate_repo(repo, params)
        entries = Souji::Git::WorktreeList.for(repo).linked
        return [] if entries.empty?

        policy = policy_for(repo, params)
        entries.filter_map do |entry|
          verdict = policy.verdict(entry)
          build_item(entry, repo: repo, verdict: verdict) if verdict
        end
      end

      def policy_for(repo, options)
        Souji::Git::WorktreePolicy.new(repo: repo, options: options, note: progress.method(:note))
      end

      # What `#verify` has to re-judge is recorded in the item itself: the
      # scenario is deliberately not consulted at apply time (FR-011a).
      def recheck_options(plan_item)
        metadata = plan_item.metadata
        {
          merged: metadata["detection"] == "merged",
          merged_into: metadata["merged_into"],
          older_than_days: metadata["older_than_days"]
        }
      end

      def build_item(entry, repo:, verdict:)
        Souji::PlanItem.new(
          id: Souji::PlanItem.generate_id("git-worktree"),
          recipe: "git-worktree",
          path: entry.path,
          reason: verdict.reason,
          # A prunable worktree's directory is already gone; there is
          # nothing left on disk to measure.
          size_bytes: verdict.detection == "prunable" ? nil : dir_size(entry.path),
          metadata: {
            "repo" => repo, "branch" => entry.branch, "head" => entry.head,
            "detection" => verdict.detection
          }.merge(verdict.metadata).compact
        )
      end

      def dir_size(path)
        total = 0
        Find.find(path) do |entry|
          total += File.size(entry) if File.file?(entry)
        rescue Errno::EACCES, Errno::ENOENT
          next
        end
        total
      end

      def owning_repo(plan_item)
        repo = plan_item.metadata["repo"] || Souji::Git::Registration.owner_of(plan_item.path)
        repo if repo && Dir.exist?(repo)
      end

      # The worktree still exists on disk. Trash the directory rather than
      # `git worktree remove --force`: untracked files do not disqualify a
      # finished worktree, so the deletion has to stay reversible. Recovery
      # is restoring the directory and `git worktree add <path> <branch>`.
      def delete_worktree_directory(repo, path)
        outcome = Souji::Trash.dispose(path)
        return outcome unless %i[trashed deleted].include?(outcome)

        Souji::Git::Command.ok?(repo, "worktree", "prune")
        outcome
      end

      # The directory is already gone (the typical `prunable` case); only
      # the registration in .git/worktrees/ is left to remove.
      def delete_registration(repo, worktree_path)
        entry_dir = Souji::Git::Registration.entry_dir(repo, worktree_path)
        return [:failed, "no .git/worktrees/<name>/ entry matched #{worktree_path}"] unless entry_dir

        Souji::Trash.dispose(entry_dir)
      end
    end
  end
end
