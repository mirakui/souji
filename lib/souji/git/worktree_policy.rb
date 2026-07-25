# frozen_string_literal: true

require "time"
require_relative "base_ref"
require_relative "command"
require_relative "commit"

module Souji
  module Git
    # When is a worktree disposable?
    #
    # One object answers that for both halves of souji: `souji plan` asks
    # what to propose, and `souji apply` asks again per item right before
    # deleting. The two have to agree, so anything that changed in between
    # — work resumed, a lock taken, a branch that moved on — turns into a
    # skip instead of a deletion.
    #
    # `options` is the recipe's params hash: `:merged`, `:merged_into`,
    # `:fetch`, `:older_than_days`. `note` receives one-line explanations
    # of near misses worth telling the user about.
    class WorktreePolicy
      # Why a worktree was caught, in the terms a plan file uses.
      Verdict = Struct.new(:detection, :reason, :metadata, keyword_init: true)

      def initialize(repo:, options: {}, note: nil)
        @repo = repo
        @options = options
        @note = note
      end

      # A Verdict, or nil when the worktree is still doing its job.
      def verdict(entry)
        # `locked` is the user saying "hands off", and git refuses to
        # remove a locked worktree anyway.
        return nil if entry.path.nil? || entry.locked
        return prunable_verdict(entry) if entry.prunable
        return nil unless present?(entry) && clean?(entry)

        merged_verdict(entry) || stale_verdict(entry)
      end

      # Re-run the judgement behind an existing plan item. Returns :ok or
      # [:skip, reason].
      def recheck(entry, detection)
        return [:skip, "worktree is locked"] if entry.locked

        case detection
        when "merged" then recheck_merged(entry)
        when "stale" then recheck_stale(entry)
        else entry.prunable ? :ok : [:skip, "worktree is no longer prunable"]
        end
      end

      private

      def prunable_verdict(entry)
        suffix = entry.prunable_reason.to_s.empty? ? "" : ": #{entry.prunable_reason}"
        Verdict.new(detection: "prunable", reason: "Worktree marked prunable by git#{suffix}", metadata: {})
      end

      def merged_verdict(entry)
        return nil unless merged?(entry)

        Verdict.new(detection: "merged",
                    reason: "#{subject(entry)} is merged into #{base.name}",
                    metadata: { "merged_into" => base.name })
      end

      def stale_verdict(entry)
        return nil unless threshold

        age = Commit.age_in_days(@repo, entry.head)
        return nil unless age && age >= threshold && anchored?(entry)

        Verdict.new(detection: "stale",
                    reason: "#{subject(entry)} last committed #{age} days ago",
                    metadata: { "older_than_days" => threshold,
                                "last_commit_at" => Commit.committed_at(@repo, entry.head)&.utc&.iso8601 })
      end

      def recheck_merged(entry)
        return [:skip, "worktree directory is gone"] unless present?(entry)
        return [:skip, "base ref #{@options[:merged_into].inspect} can no longer be resolved"] unless base
        return [:skip, "worktree is no longer merged into #{base.name}"] unless merged?(entry)

        clean?(entry) ? :ok : [:skip, "worktree has uncommitted changes"]
      end

      def recheck_stale(entry)
        return [:skip, "worktree directory is gone"] unless present?(entry)

        age = Commit.age_in_days(@repo, entry.head)
        return [:skip, "last commit date is unreadable"] unless age && threshold
        return [:skip, "worktree has a commit newer than #{threshold} days"] if age < threshold
        return [:skip, "detached HEAD is not reachable from any ref"] unless anchored?(entry, note: false)

        clean?(entry) ? :ok : [:skip, "worktree has uncommitted changes"]
      end

      def merged?(entry)
        !base.nil? && base.contains?(@repo, entry.head)
      end

      # Resolved at most once per policy: it can cost a fetch.
      def base
        return @base if defined?(@base)

        @base = @options[:merged] ? resolve_base : nil
      end

      def resolve_base
        resolved = BaseRef.resolve(@repo, override: @options[:merged_into], fetch: @options[:fetch])
        if resolved.nil?
          emit("#{@repo}: no base ref to compare against, skipping the merged check")
        elsif resolved.fetch_result == :failed
          emit("#{@repo}: fetch failed, judging against the cached #{resolved.name}")
        end
        resolved
      end

      def threshold
        @options[:older_than_days]
      end

      # Removing a worktree leaves its branch behind, so the commits
      # survive. A detached HEAD has no such anchor: unless some other ref
      # contains the commit, deleting the worktree hands it to gc.
      def anchored?(entry, note: true)
        return true if entry.branch
        return true if Commit.referenced?(@repo, entry.head)

        emit("#{entry.path}: detached HEAD is not reachable from any ref, leaving it alone") if note
        false
      end

      def present?(entry)
        File.directory?(entry.path.to_s)
      end

      # Untracked files are deliberately not disqualifying: build output
      # and .env files would otherwise mask every finished worktree. They
      # are why deletion routes through the trash.
      def clean?(entry)
        Command.capture(entry.path, "status", "--porcelain", "--untracked-files=no") == ""
      end

      def subject(entry)
        entry.branch ? "Branch #{entry.branch}" : "Detached HEAD #{entry.head.to_s[0, 9]}"
      end

      def emit(message)
        @note&.call(message)
      end
    end
  end
end
