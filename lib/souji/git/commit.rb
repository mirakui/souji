# frozen_string_literal: true

require_relative "command"

module Souji
  module Git
    # Facts about a single commit that bear on whether the worktree sitting
    # on it is still worth keeping.
    module Commit
      SECONDS_PER_DAY = 86_400

      module_function

      # Whole days since the commit was committed, or nil when the commit
      # cannot be read.
      def age_in_days(repo, sha, now: Time.now)
        epoch = committed_at_epoch(repo, sha)
        return nil unless epoch

        (now.to_i - epoch) / SECONDS_PER_DAY
      end

      def committed_at(repo, sha)
        epoch = committed_at_epoch(repo, sha)
        epoch && Time.at(epoch)
      end

      def committed_at_epoch(repo, sha)
        raw = Command.capture(repo, "show", "--no-patch", "--format=%ct", sha.to_s)
        raw&.match?(/\A\d+\z/) ? raw.to_i : nil
      end

      # Does any ref still contain this commit? A commit no ref reaches
      # lives only as long as the worktree pointing at it, so deleting that
      # worktree hands it to gc.
      def referenced?(repo, sha)
        found = Command.capture(repo, "for-each-ref", "--contains", sha.to_s, "--count=1", "--format=%(refname)")
        !found.nil? && !found.empty?
      end
    end
  end
end
