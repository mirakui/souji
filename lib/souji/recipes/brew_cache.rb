# frozen_string_literal: true

require_relative "../recipe"
require_relative "../external/command"
require_relative "../external/human_size"
require_relative "../external/delegated_prune"

module Souji
  module Recipes
    # Asks Homebrew to remove its outdated downloads and caches.
    #
    # Unusually for this family, Homebrew *can* enumerate: `brew cleanup
    # --dry-run` lists every path and totals them. souji still proposes a
    # single item, because `brew cleanup` has no per-file mode. Splitting
    # the listing into one item per path would give each item a `#delete`
    # that re-ran the whole cleanup and removed the other items as a side
    # effect, which breaks the per-item contract outright.
    #
    # What the dry run buys instead is a **real** `size_bytes` rather than
    # an upper bound, plus the first handful of paths in metadata so the
    # plan is reviewable.
    #
    # Homebrew prints binary quantities behind SI-looking labels -- its
    # `34.6MB` is 34.6 MiB -- and writes thousands separators into the file
    # counts beside them, which is why the size parsing is explicit about
    # its base.
    class BrewCache < Souji::Recipe
      include Souji::External::DelegatedPrune

      recipe_name "brew-cache"
      required_external_commands "brew"
      scope_free!
      description "Ask Homebrew to remove outdated downloads and caches (brew cleanup --prune=all)"
      param :prune_days,
            "Remove downloads older than this many days instead of all of them (default: all)"

      WOULD_REMOVE = /\AWould remove: (.+?) \(([^()]*)\)\s*\z/
      FREED_TOTAL = /would free approximately (.+?) of disk space/
      PREVIEW_PATHS = 20

      def enumerate(_target_roots, params)
        prune = prune_value(params[:prune_days])
        preview = dry_run(prune)
        return [] if preview[:paths].empty?

        [build_item(prune, preview)]
      end

      # Homebrew's dry run is non-mutating, so it doubles as the re-check
      # that there is still something to clean.
      def verify(plan_item)
        shared = verify_tool_and_cache_dir(plan_item)
        return shared unless shared == :ok

        return [:skip, "brew reports nothing to clean"] if dry_run(plan_item.metadata["prune"])[:paths].empty?

        :ok
      end

      def delete(plan_item)
        run_delegated(plan_item)
      end

      private

      def prune_value(prune_days)
        prune_days ? prune_days.to_i.to_s : "all"
      end

      # The dry run MUST carry the same --prune value as the command
      # #delete will run, or the size reported is a size for a different
      # operation.
      def dry_run(prune)
        progress.scanning("homebrew cleanup (--prune=#{prune})")
        output = Souji::External::Command.capture(
          *cleanup_argv(prune), "--dry-run",
          timeout: Souji::External::Command::SLOW_PROBE_TIMEOUT
        ).to_s
        { paths: parse_paths(output), total: parse_total(output) }
      end

      def cleanup_argv(prune)
        ["brew", "cleanup", "--prune=#{prune}"]
      end

      def parse_paths(output)
        output.lines.filter_map do |line|
          match = line.match(WOULD_REMOVE)
          match && match[1]
        end
      end

      def parse_total(output)
        match = output.match(FREED_TOTAL)
        return nil unless match

        Souji::External::HumanSize.parse(match[1], base: :binary)
      end

      def build_item(prune, preview)
        delegated_item(
          recipe: "brew-cache",
          key: "cleanup",
          argv: cleanup_argv(prune),
          cache_dir: cache_dir,
          reason: reason_for(prune, preview),
          size_bytes: preview[:total],
          size_basis: "brew cleanup --prune=#{prune} --dry-run total",
          extra: {
            "prune" => prune,
            "would_remove_count" => preview[:paths].size,
            "would_remove" => preview[:paths].first(PREVIEW_PATHS)
          }
        )
      end

      def reason_for(prune, preview)
        scope = prune == "all" ? "all outdated downloads and caches" : "downloads older than #{prune} days"
        "Homebrew removes #{scope} (#{preview[:paths].size} paths)"
      end

      def cache_dir
        Souji::External::Command.capture("brew", "--cache")
      end
    end
  end
end
