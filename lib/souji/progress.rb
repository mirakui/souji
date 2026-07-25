# frozen_string_literal: true

module Souji
  # Human-facing progress reporter for `souji plan`.
  #
  # Progress is diagnostic output, so it goes to stderr: stdout stays
  # reserved for the deliverable one-line summary (see the
  # "stdout / stderr separation" section of
  # specs/001-souji-cli-recipe-plan/contracts/cli-commands.md).
  #
  # `souji plan` reports the scenario being run, each recipe invocation and
  # each target a recipe scans; `--quiet` swaps the live reporter for
  # `Progress.null`, which discards everything.
  #
  # Recipes reach their reporter through `Souji::Recipe#progress`, which the
  # scenario injects before calling `#enumerate`.
  class Progress
    PREFIX = "[souji]"

    attr_reader :io

    # A reporter that writes nothing. Used by `--quiet` and as the default
    # for library callers that did not ask for progress.
    def self.null
      new(io: nil)
    end

    def initialize(io: $stderr)
      @io = io
    end

    def enabled?
      !@io.nil?
    end

    def scenario_start(path, target_roots)
      emit("scenario #{path}")
      emit("targets: #{target_roots.join(", ")}") unless target_roots.empty?
    end

    def recipe_start(name, index:, total:, targets: [])
      suffix = targets.empty? ? "" : " (targets: #{targets.join(", ")})"
      emit("[#{index}/#{total}] recipe #{name}#{suffix}")
    end

    # `target` is whatever the recipe is currently looking at: a directory,
    # a lockfile, or a description of an external query.
    def scanning(target)
      emit("  scanning #{target}")
    end

    def recipe_finish(name, item_count)
      emit("recipe #{name}: #{item_count} #{item_count == 1 ? "item" : "items"}")
    end

    def recipe_skipped(name, command)
      emit("recipe #{name.inspect} skipped: command #{command.inspect} not found")
    end

    private

    def emit(message)
      return unless enabled?

      @io.puts("#{PREFIX} #{message}")
    end
  end
end
