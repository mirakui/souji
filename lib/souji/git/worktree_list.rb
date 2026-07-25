# frozen_string_literal: true

require_relative "command"

module Souji
  module Git
    # `git worktree list --porcelain` as data.
    #
    # git documents that the main worktree comes first and the linked
    # worktrees follow, so `#linked` is everything after the first record.
    # That ordering is the only dependable way to tell the main worktree
    # apart — comparing paths misfires the moment a repository is reached
    # through a symlink or a path the OS normalises (`/tmp` on macOS).
    class WorktreeList
      Entry = Struct.new(:path, :head, :branch, :detached, :locked, :prunable, :prunable_reason,
                         keyword_init: true)

      def self.for(repo)
        output = Command.capture(repo, "worktree", "list", "--porcelain")
        new(output ? parse(output) : [])
      end

      # Records are introduced by their `worktree <path>` line, which is
      # sturdier than splitting on blank lines: a truncated final record
      # still parses.
      def self.parse(text)
        entries = []
        current = nil
        text.each_line do |line|
          chomped = line.chomp
          if (match = chomped.match(/\Aworktree (.+)\z/))
            entries << current if current
            current = Entry.new(path: match[1])
          elsif current
            apply_attribute(current, chomped)
          end
        end
        entries << current if current
        entries
      end

      def self.apply_attribute(entry, line)
        case line
        when %r{\Abranch refs/heads/(.+)\z} then entry.branch = ::Regexp.last_match(1)
        when /\AHEAD (.+)\z/ then entry.head = ::Regexp.last_match(1)
        when /\Adetached\z/ then entry.detached = true
        when /\Alocked(?: .*)?\z/ then entry.locked = true
        when /\Aprunable(?: (.*))?\z/
          entry.prunable = true
          entry.prunable_reason = ::Regexp.last_match(1).to_s
        end
      end

      attr_reader :entries

      def initialize(entries)
        @entries = entries
      end

      def linked
        entries.drop(1)
      end

      def find(path)
        entries.find { |entry| entry.path == path }
      end
    end
  end
end
