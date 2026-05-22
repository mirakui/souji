# frozen_string_literal: true

require "open3"
require "find"
require_relative "../recipe"
require_relative "../plan_item"
require_relative "../errors"

module Souji
  module Recipes
    # Identifies git worktrees that git itself has flagged as prunable
    # (HEAD missing on disk, repo gone, etc.) and proposes them for
    # deletion via `git worktree remove --force`.
    #
    # Discovery strategy:
    # 1. Walk each target_root looking for directories containing a
    #    .git/worktrees/ folder (i.e., a git repository that has at
    #    least one worktree registered).
    # 2. Run `git -C <repo> worktree list --porcelain` and parse the
    #    output looking for entries with a `prunable` line.
    # 3. Emit a PlanItem per prunable entry.
    class GitWorktree < Souji::Recipe
      recipe_name "git-worktree"
      required_external_commands "git"
      description "Remove abandoned git worktrees (HEAD-missing or marked prunable by git)"

      def enumerate(target_roots, _params)
        target_roots
          .flat_map { |root| find_git_repos(root) }
          .uniq
          .sort
          .flat_map { |repo| enumerate_repo(repo) }
      end

      def verify(plan_item)
        repo = repo_from_metadata(plan_item) || repo_for(plan_item.path)
        return [:skip, "owning git repository no longer exists"] unless repo && Dir.exist?(repo)
        return [:skip, "worktree no longer registered with git"] unless still_prunable?(repo, plan_item.path)

        :ok
      end

      def delete(plan_item)
        repo = repo_from_metadata(plan_item) || repo_for(plan_item.path)
        return [:failed, "owning git repository missing"] unless repo && Dir.exist?(repo)

        if Dir.exist?(plan_item.path)
          delete_via_git(repo, plan_item.path)
        else
          # Worktree directory is already gone (the typical "prunable"
          # case); just remove the registration in .git/worktrees/.
          delete_metadata(repo, plan_item.path)
        end
      end

      private

      # Find every directory under `root` that has a .git/worktrees/
      # subdirectory (i.e., a git repo that has registered worktrees).
      def find_git_repos(root)
        return [] unless Dir.exist?(root)

        repos = []
        Find.find(root) do |path|
          next unless File.directory?(path)
          next unless File.basename(path) == ".git"

          # `path` is the .git directory. Its parent is the repo root.
          repos << File.dirname(path)
          Find.prune
        rescue Errno::EACCES, Errno::ENOENT
          Find.prune
        end
        repos
      end

      def enumerate_repo(repo)
        stdout, _stderr, status = Open3.capture3("git", "-C", repo, "worktree", "list", "--porcelain")
        return [] unless status.success?

        parse_porcelain(stdout).filter_map do |entry|
          next unless entry[:prunable] && entry[:worktree] && entry[:worktree] != repo

          build_plan_item(entry, repo: repo)
        end
      end

      def parse_porcelain(text)
        entries = []
        current = {}
        text.each_line do |line|
          line = line.chomp
          if line.empty?
            entries << current unless current.empty?
            current = {}
            next
          end
          case line
          when /\Aworktree (.+)\z/ then current[:worktree] = ::Regexp.last_match(1)
          when /\AHEAD (.+)\z/ then current[:head] = ::Regexp.last_match(1)
          when /\Abranch (.+)\z/ then current[:branch] = ::Regexp.last_match(1)
          when /\Aprunable( |\z)(.*)\z/ then current[:prunable] = true
                                             current[:prunable_reason] = ::Regexp.last_match(2)
          when /\Adetached\z/ then current[:detached] = true
          end
        end
        entries << current unless current.empty?
        entries
      end

      def build_plan_item(entry, repo:)
        suffix = entry[:prunable_reason].to_s.empty? ? "" : ": #{entry[:prunable_reason]}"
        Souji::PlanItem.new(
          id: Souji::PlanItem.generate_id("git-worktree"),
          recipe: "git-worktree",
          path: entry[:worktree],
          reason: "Worktree marked prunable by git#{suffix}",
          size_bytes: nil,
          metadata: {
            "repo" => repo,
            "branch" => entry[:branch],
            "head" => entry[:head]
          }.compact
        )
      end

      def repo_from_metadata(plan_item)
        plan_item.metadata["repo"]
      end

      # Walk upwards from `path` until we find a .git directory that
      # mentions `path` in its worktrees subdir. Returns the repo root.
      def repo_for(path)
        current = File.expand_path(path)
        until current == "/" || current.empty?
          parent = File.dirname(current)
          git_dir_candidate = File.join(parent, ".git")
          worktrees_dir = File.join(git_dir_candidate, "worktrees")
          return parent if Dir.exist?(worktrees_dir) && Dir.children(worktrees_dir).any?

          current = parent
        end
        nil
      end

      def still_prunable?(repo, worktree_path)
        stdout, _stderr, status = Open3.capture3("git", "-C", repo, "worktree", "list", "--porcelain")
        return false unless status.success?

        parse_porcelain(stdout).any? do |entry|
          entry[:worktree] == worktree_path && entry[:prunable]
        end
      end

      def delete_via_git(repo, path)
        _stdout, stderr, status = Open3.capture3("git", "-C", repo, "worktree", "remove", "--force", path)
        return :deleted if status.success?

        [:failed, "git worktree remove failed: #{stderr.strip}"]
      end

      # Remove only the metadata directory in .git/worktrees/ that
      # corresponds to this worktree path. We identify it by reading
      # each entry's `gitdir` file, which points back at the worktree's
      # ".git" link file.
      def delete_metadata(repo, worktree_path)
        worktrees_root = File.join(repo, ".git", "worktrees")
        return [:failed, ".git/worktrees missing"] unless Dir.exist?(worktrees_root)

        Dir.children(worktrees_root).each do |name|
          gitdir_file = File.join(worktrees_root, name, "gitdir")
          next unless File.file?(gitdir_file)

          recorded = File.read(gitdir_file).strip
          # `recorded` is the path to the worktree's `.git` link file,
          # i.e., "<worktree-path>/.git"
          next unless recorded == File.join(worktree_path, ".git")

          require_relative "../trash"
          outcome = Souji::Trash.dispose(File.join(worktrees_root, name))
          return outcome
        end
        [:failed, "no .git/worktrees/<name>/ entry matched #{worktree_path}"]
      end
    end
  end
end
