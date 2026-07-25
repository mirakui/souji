# frozen_string_literal: true

require_relative "command"

module Souji
  module Git
    # The ref a branch must already be contained in before its worktree
    # counts as finished work, resolved once per repository.
    #
    # Resolution order: the scenario's explicit override, then
    # refs/remotes/origin/HEAD (whatever this clone itself calls the
    # default branch), then origin/main and origin/master.
    class BaseRef
      FALLBACKS = %w[origin/main origin/master].freeze

      # `git fetch` must never block `souji plan` on a credential prompt or
      # an unknown host key, so it runs strictly non-interactively and
      # gives up quickly.
      FETCH_ENV = {
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_SSH_COMMAND" => "ssh -o BatchMode=yes -o ConnectTimeout=10"
      }.freeze

      class << self
        # A BaseRef, or nil when this repository offers nothing to compare
        # against (no remote, no origin/HEAD, no conventional fallback).
        def resolve(repo, override: nil, fetch: false)
          name = override || detect(repo)
          return nil unless name

          fetch_result = fetch ? refresh(repo, name) : nil
          commit = Command.rev_parse(repo, name)
          return nil unless commit

          new(name: name, commit: commit, fetch_result: fetch_result)
        end

        def detect(repo)
          symbolic = Command.capture(repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
          return symbolic.delete_prefix("refs/remotes/") if symbolic && !symbolic.empty?

          FALLBACKS.find { |ref| Command.rev_parse(repo, ref) }
        end

        # Bring `name`'s remote-tracking ref up to date. Answers :failed
        # when the fetch did not happen — offline, expired credential,
        # remote gone. The caller then carries on against the cached ref
        # rather than giving up on the repository.
        def refresh(repo, name)
          remote, branch = split(name)
          return :failed unless remote && Command.capture(repo, "config", "--get", "remote.#{remote}.url")

          Command.ok?(repo, "fetch", "--quiet", remote, branch, env: FETCH_ENV) ? :ok : :failed
        end

        def split(name)
          remote, _, branch = name.delete_prefix("refs/remotes/").partition("/")
          return [nil, nil] if remote.empty? || branch.empty?

          [remote, branch]
        end
      end

      # `fetch_result` is nil when no fetch was asked for, :ok when one
      # succeeded, and :failed when one was attempted and did not land.
      attr_reader :name, :commit, :fetch_result

      def initialize(name:, commit:, fetch_result: nil)
        @name = name
        @commit = commit
        @fetch_result = fetch_result
      end

      def contains?(repo, commit_ish)
        return false unless commit_ish

        Command.ok?(repo, "merge-base", "--is-ancestor", commit_ish, commit)
      end
    end
  end
end
