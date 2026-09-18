# frozen_string_literal: true

require_relative "../recipe"
require_relative "../external/command"
require_relative "../external/delegated_prune"

module Souji
  module Recipes
    # Asks pnpm to drop the packages in its store that no project
    # references.
    #
    # `pnpm store prune` removes only unreferenced packages, so like
    # `uv cache prune` this is the safe end of the family. Delegating is
    # not merely polite here: the store is content-addressable with its own
    # index, and every `node_modules` pnpm has ever built hardlinks into
    # it. souji unlinking objects itself would leave the index describing
    # files that are gone.
    #
    # This recipe deliberately reports **no size at all**, not even an
    # upper bound:
    #
    # - pnpm has no `--dry-run` and no size subcommand, so the tool cannot
    #   say.
    # - Walking the store would be worse than useless. Its contents are
    #   hardlinked into the `node_modules` trees the `node-modules` recipe
    #   already measures, so those bytes would be counted twice, and
    #   pruning frees only the links nothing points at.
    #
    # `pnpm store status` is not used for any of this: it answers whether
    # stored packages have been *modified*, which is a tamper check, not a
    # statement about what is reclaimable.
    class PnpmStore < Souji::Recipe
      include Souji::External::DelegatedPrune

      recipe_name "pnpm-store"
      required_external_commands "pnpm"
      scope_free!
      description "Ask pnpm to remove unreferenced packages from its store (pnpm store prune)"

      def enumerate(_target_roots, _params)
        dir = store_path
        return [] unless dir && Dir.exist?(dir)

        progress.scanning("pnpm store (#{dir})")
        [build_item(dir)]
      end

      def verify(plan_item)
        verify_tool_and_cache_dir(plan_item)
      end

      def delete(plan_item)
        run_delegated(plan_item)
      end

      private

      def store_path
        Souji::External::Command.capture("pnpm", "store", "path")
      end

      def build_item(dir)
        delegated_item(
          recipe: "pnpm-store",
          key: "prune",
          argv: %w[pnpm store prune],
          cache_dir: dir,
          reason: "pnpm removes the packages in its store that no project references any more",
          size_basis: "not measured: pnpm reports neither, and the store is hardlinked into " \
                      "the node_modules trees node-modules already counts"
        )
      end
    end
  end
end
