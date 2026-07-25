# frozen_string_literal: true

module Souji
  module Git
    # The bookkeeping git keeps for a linked worktree in
    # `.git/worktrees/<name>/`, addressed from the worktree's own path.
    #
    # Needed because a worktree can outlive its directory: once the
    # directory is gone there is no `git -C <worktree>` left to ask, and the
    # only thing to clean up is this registration.
    module Registration
      module_function

      # Walk up from `path` until we find a repository that has registered
      # worktrees. Returns the repository root, or nil.
      def owner_of(path)
        current = File.expand_path(path)
        until current == "/" || current.empty?
          parent = File.dirname(current)
          worktrees_dir = File.join(parent, ".git", "worktrees")
          return parent if Dir.exist?(worktrees_dir) && Dir.children(worktrees_dir).any?

          current = parent
        end
        nil
      end

      # The `.git/worktrees/<name>/` directory that belongs to
      # `worktree_path`, identified by its `gitdir` file — which records the
      # path of the worktree's own `.git` link file.
      def entry_dir(repo, worktree_path)
        worktrees_root = File.join(repo, ".git", "worktrees")
        return nil unless Dir.exist?(worktrees_root)

        wanted = File.join(worktree_path, ".git")
        Dir.children(worktrees_root).each do |name|
          gitdir_file = File.join(worktrees_root, name, "gitdir")
          next unless File.file?(gitdir_file)
          return File.join(worktrees_root, name) if File.read(gitdir_file).strip == wanted
        end
        nil
      end
    end
  end
end
