# frozen_string_literal: true

module Souji
  # Filesystem primitives shared by the pure-filesystem recipes.
  #
  # Every recipe that hunts for regenerable build output has the same three
  # needs: walk a target root without descending into the very directories
  # it is looking for, measure what it found, and decide how stale it is.
  # Each of those has a sharp edge that is not obvious, so they live here
  # once rather than being re-derived per recipe:
  #
  # - the walk must be deterministic (plan items have to come out in the
  #   same order on every run), must never follow a symlinked directory,
  #   and must survive an unreadable subtree;
  # - `dir_size` must lstat, not stat: a `.terraform/providers` entry is
  #   often a symlink into the shared plugin cache, and following it both
  #   inflates the item's size and double-counts it against the
  #   `terraform-provider` recipe;
  # - staleness is measured from the artifact's own generation time, never
  #   from project source activity. A repository whose sources were edited
  #   today can still hold a provider cache from last year, and that cache
  #   is exactly what we came for.
  module FsScan
    # Directories that hold no repository or project root worth visiting
    # but do hold enough files to dominate a walk. Callers subtract their
    # own target from this list -- `terraform-dir` needs to enter
    # `.terraform`, `node-modules` needs to enter `node_modules` -- which
    # is also why a single shared walk across recipes is not possible.
    SKIP_DIR_NAMES = %w[
      .git node_modules .terraform .venv venv .direnv __pycache__
      vendor bundle dist build target coverage
      .next .nuxt .turbo .cache .pytest_cache
    ].freeze

    # Entries `newest_mtime_under` will look at before giving up.
    DEFAULT_MTIME_BUDGET = 20_000

    SECONDS_PER_DAY = 86_400

    WALK_ERRORS = [Errno::EACCES, Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR].freeze

    module_function

    # Yields every directory at or below `root`, parents before children
    # and siblings in sorted order. A block returning `:prune` stops the
    # descent into that directory; `skip` prunes by basename before the
    # block ever sees it.
    #
    # Symlinked directories are never descended into, so a symlink loop
    # cannot hang the walk and a link out of the target roots cannot widen
    # the scope.
    def walk_dirs(root, skip: SKIP_DIR_NAMES)
      root = File.expand_path(root)
      return unless directory_no_follow?(root)

      skip_set = skip.to_a.to_set
      stack = [root]
      until stack.empty?
        dir = stack.pop
        next if yield(dir) == :prune

        stack.concat(child_dirs(dir, skip_set).reverse)
      end
    end

    # Total size of the regular files at or below `path`, in bytes.
    # Symlinks count as zero: what a symlink points at is not ours to
    # reclaim, and it may well be counted by another recipe.
    def dir_size(path)
      total = 0
      walk_dirs(path, skip: []) do |dir|
        total += files_size(dir)
      end
      total
    end

    # The newest mtime among `paths`, ignoring the ones that do not exist.
    # Takes paths rather than a directory because the callers know exactly
    # which few files a tool rewrites when it installs -- an install
    # receipt is a far better staleness signal than a directory mtime.
    def newest_mtime(paths)
      paths.compact.filter_map { |path| mtime_or_nil(path) }.max
    end

    # The newest mtime anywhere under `root`, and whether the walk ran out
    # of budget before it finished. A truncated answer is a partial one, so
    # callers record the flag rather than pretending the result is exact.
    #
    # This is informational only: no recipe gates a deletion on project
    # source activity (see the module docstring).
    def newest_mtime_under(root, skip: SKIP_DIR_NAMES, budget: DEFAULT_MTIME_BUDGET)
      newest = nil
      seen = 0
      walk_dirs(root, skip: skip) do |dir|
        next :prune if seen >= budget

        entries = children(dir)
        seen += entries.size
        entries.each do |name|
          mtime = mtime_or_nil(File.join(dir, name))
          newest = mtime if mtime && (newest.nil? || mtime > newest)
        end
      end
      [newest, seen >= budget]
    end

    # True when `path` is `root` itself or sits underneath it, for any of
    # the given roots.
    def within_any?(path, roots)
      normalized = File.expand_path(path)
      roots.any? do |root|
        normalized_root = File.expand_path(root)
        normalized == normalized_root || normalized.start_with?("#{normalized_root}/")
      end
    end

    # Whole days between `time` and now. nil in, nil out, so a caller with
    # no timestamp to work from can pass it straight through.
    def days_since(time, now: Time.now)
      return nil unless time

      ((now - time) / SECONDS_PER_DAY).floor
    end

    # --- smaller shared pieces, also useful on their own ---------------

    def child_dirs(dir, skip_set)
      children(dir).filter_map do |name|
        next if skip_set.include?(name)

        child = File.join(dir, name)
        child if directory_no_follow?(child)
      end
    end

    def children(dir)
      Dir.children(dir).sort
    rescue *WALK_ERRORS
      []
    end

    def files_size(dir)
      total = 0
      children(dir).each do |name|
        stat = lstat_or_nil(File.join(dir, name))
        total += stat.size if stat&.file?
      end
      total
    end

    def directory_no_follow?(path)
      stat = lstat_or_nil(path)
      !stat.nil? && stat.directory?
    end

    def mtime_or_nil(path)
      lstat_or_nil(path)&.mtime
    end

    def lstat_or_nil(path)
      File.lstat(path)
    rescue *WALK_ERRORS
      nil
    end
  end
end
