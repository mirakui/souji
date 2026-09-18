# frozen_string_literal: true

require_relative "command"
require_relative "../plan_item"
require_relative "../recipe"

module Souji
  module External
    # Shared machinery for the recipes that ask a tool to prune its own
    # cache instead of deleting the tool's files themselves.
    #
    # The delegation is the safety argument. `uv`, `pnpm` and `mise` keep
    # content-addressable stores with their own indexes; souji walking in
    # and unlinking objects would leave the index describing files that no
    # longer exist. Asking the tool means the tool's notion of
    # "unreferenced" is the one that applies, and its index stays true.
    #
    # It also costs something, and the cost is recorded rather than
    # hidden: the tool decides what goes, so souji cannot enumerate the
    # individual objects, cannot promise an exact byte count, and cannot
    # send anything to the trash. Every item built here is therefore
    # marked irreversible and carries the literal argv `#delete` will run,
    # so the plan a reviewer approves is a readable script.
    module DelegatedPrune
      # A single opaque unit of prune work.
      #
      # `size_bytes` is only ever a figure souji believes will actually be
      # freed. When a tool cannot say — `uv cache prune` has no dry run —
      # it stays nil and the whole-cache size goes in
      # `size_bytes_upper_bound` instead, with `size_basis` naming how the
      # number was obtained. Summing an upper bound into the plan's total
      # would turn "at least this much" into a promise souji cannot keep.
      def delegated_item(recipe:, key:, argv:, reason:, cache_dir: nil,
                         size_bytes: nil, upper_bound_bytes: nil, size_basis: nil, extra: {})
        argv = argv.map(&:to_s)
        Souji::PlanItem.new(
          id: Souji::PlanItem.generate_id(recipe),
          recipe: recipe,
          path: "#{recipe}://#{key}",
          reason: reason,
          size_bytes: size_bytes,
          metadata: base_metadata(argv, cache_dir, upper_bound_bytes, size_basis).merge(extra).compact
        )
      end

      # Runs the argv recorded in the item, and nothing else. Always
      # :deleted rather than :trashed: souji never holds these paths, so
      # there is nothing for Souji::Trash to move.
      def run_delegated(plan_item, timeout: Command::PRUNE_TIMEOUT)
        argv = plan_item.metadata["argv"]
        return [:failed, "plan item records no command to run"] unless argv.is_a?(Array) && !argv.empty?

        result = Command.run(*argv, timeout: timeout)
        return :deleted if result.success?
        return [:failed, "#{argv.join(" ")} timed out after #{timeout}s"] if result.timed_out

        [:failed, "#{argv.join(" ")} failed: #{last_line(result.stderr)}"]
      end

      # The two re-checks available for every delegated item. Recipes whose
      # tool offers a non-mutating re-probe add it on top; the ones that do
      # not say so in their own class documentation, so a thin verify reads
      # as a fact about the tool rather than as an oversight.
      def verify_tool_and_cache_dir(plan_item)
        command = plan_item.metadata["command"]
        return [:skip, "#{command} is no longer on PATH"] unless Souji::Recipe.available?(command.to_s)

        dir = plan_item.metadata["cache_dir"]
        return [:skip, "cache directory #{dir} no longer exists"] if dir && !Dir.exist?(dir)

        :ok
      end

      private

      def base_metadata(argv, cache_dir, upper_bound_bytes, size_basis)
        {
          "irreversible" => true,
          "scope_free" => true,
          "command" => argv.first,
          "argv" => argv,
          "delegated_to" => argv.join(" "),
          "cache_dir" => cache_dir,
          "size_bytes_upper_bound" => upper_bound_bytes,
          "size_basis" => size_basis
        }
      end

      def last_line(text)
        line = text.to_s.lines.map(&:strip).reject(&:empty?).last || "no error output"
        line.length > 200 ? "#{line[0, 197]}..." : line
      end
    end
  end
end
