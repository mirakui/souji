# frozen_string_literal: true

require "open3"

module Souji
  # Thin, read-only plumbing over the `git` executable, shared by the
  # git-backed recipes.
  module Git
    # Runs `git -C <dir> ...` and turns the result into plain Ruby.
    #
    # Nothing here raises. A repository that is corrupt, unreadable, or
    # simply not a repository answers nil/false instead of aborting the
    # `souji plan` that happened to walk into it.
    module Command
      module_function

      # git's stdout with surrounding whitespace stripped, or nil when git
      # exited non-zero.
      def capture(dir, *, env: {})
        stdout, _stderr, status = Open3.capture3(env, "git", "-C", dir, *)
        return nil unless status.success?

        stdout.strip
      end

      def ok?(dir, *, env: {})
        _stdout, _stderr, status = Open3.capture3(env, "git", "-C", dir, *)
        status.success?
      end

      # The full commit sha `rev` names, or nil when it names nothing (or
      # names something that is not a commit).
      def rev_parse(dir, rev)
        capture(dir, "rev-parse", "--verify", "--quiet", "#{rev}^{commit}")
      end
    end
  end
end
