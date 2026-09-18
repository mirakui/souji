# frozen_string_literal: true

require_relative "../recipe"
require_relative "../external/command"
require_relative "../external/delegated_prune"

module Souji
  module Recipes
    # Asks uv to drop the unreachable objects from its own cache.
    #
    # `uv cache prune` removes only what nothing references, so this is the
    # safe end of the delegated-prune family: it is idempotent and it is
    # the operation uv itself documents for reclaiming space.
    #
    # One opaque item, because uv offers no way to do better. There is no
    # `--dry-run`, and `uv cache size` reports the size of the *whole*
    # cache rather than the reclaimable part, so souji can honestly offer
    # an upper bound and nothing more. Enumerating the cache directory
    # ourselves would mean souji deciding what is unreachable, which is
    # exactly the judgement being delegated.
    #
    # `#verify` is therefore only the shared two checks -- uv still on
    # PATH, cache directory still present. uv has no non-mutating probe
    # that would tell us more, and that is a fact about uv rather than a
    # gap here.
    class UvCache < Souji::Recipe
      include Souji::External::DelegatedPrune

      recipe_name "uv-cache"
      required_external_commands "uv"
      scope_free!
      description "Ask uv to prune unreachable objects from its cache (uv cache prune)"

      def enumerate(_target_roots, _params)
        dir = cache_dir
        return [] unless dir && Dir.exist?(dir)

        progress.scanning("uv cache (#{dir})")
        [build_item(dir)]
      end

      def verify(plan_item)
        verify_tool_and_cache_dir(plan_item)
      end

      def delete(plan_item)
        run_delegated(plan_item)
      end

      private

      def cache_dir
        Souji::External::Command.capture("uv", "cache", "dir")
      end

      # `uv cache size` is still marked experimental and warns on stderr,
      # which is harmless -- the byte count is on stdout. When it is not
      # available the item simply has no upper bound rather than a guess.
      def cache_size_bytes
        raw = Souji::External::Command.capture("uv", "cache", "size",
                                               timeout: Souji::External::Command::SLOW_PROBE_TIMEOUT)
        Integer(raw, exception: false) if raw
      end

      def build_item(dir)
        delegated_item(
          recipe: "uv-cache",
          key: "prune",
          argv: %w[uv cache prune],
          cache_dir: dir,
          reason: "uv prunes the objects in its cache that nothing references any more",
          upper_bound_bytes: cache_size_bytes,
          size_basis: "uv cache size (the whole cache; prune removes only unreachable objects)"
        )
      end
    end
  end
end
