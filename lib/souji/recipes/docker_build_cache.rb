# frozen_string_literal: true

require_relative "../recipe"
require_relative "../external/command"
require_relative "../external/human_size"
require_relative "../external/delegated_prune"
require_relative "../external/docker"

module Souji
  module Recipes
    # Asks docker to prune the reclaimable part of its buildkit cache.
    #
    # One opaque item, unlike its two docker siblings, and the reason is
    # worth recording because per-record pruning looks available and is
    # not:
    #
    # - `docker buildx du` does list per-record ids, but the vast majority
    #   report `"0B"` with the real bytes attributed to a handful of
    #   records. A few hundred plan rows summing to almost nothing, with
    #   the actual gigabytes hidden in five of them, is a fiction dressed
    #   up as precision.
    # - There is no supported per-record delete. `docker buildx prune`
    #   takes no id, and a record's removal cascades to its parents -- so a
    #   per-item `#delete` would remove other plan items as a side effect,
    #   which breaks the per-item contract.
    #
    # The size comes from `docker system df`, whose `Reclaimable` for the
    # Build Cache row is what a plain prune actually frees. It is NOT taken
    # from `docker buildx du`'s trailing `Reclaimable:` line, which counts
    # records shared with live images and on the machine this was written
    # against reported 13.59 GB where a prune frees 8.709 GB.
    #
    # `-a` is never passed, so cache still in use is left alone.
    class DockerBuildCache < Souji::Recipe
      include Souji::External::DelegatedPrune

      recipe_name "docker-build-cache"
      required_external_commands "docker"
      scope_free!
      description "Ask docker to prune reclaimable buildkit cache (docker builder prune)"
      param :unused_for_days,
            "Only prune cache records unused for at least this many days (default: all reclaimable)"

      BUILD_CACHE_TYPE = "Build Cache"

      def enumerate(_target_roots, params)
        row = build_cache_row
        return [] unless row

        reclaimable = Souji::External::HumanSize.parse(row["Reclaimable"])
        return [] if reclaimable.nil? || reclaimable.zero?

        Souji::External::Docker.note_vm(progress)
        [build_item(row, reclaimable, params[:unused_for_days])]
      end

      def verify(plan_item)
        shared = verify_tool_and_cache_dir(plan_item)
        return shared unless shared == :ok

        row = build_cache_row
        reclaimable = row && Souji::External::HumanSize.parse(row["Reclaimable"])
        return [:skip, "docker reports no reclaimable build cache"] if reclaimable.nil? || reclaimable.zero?

        :ok
      end

      def delete(plan_item)
        run_delegated(plan_item)
      end

      private

      def build_cache_row
        progress.scanning("docker build cache")
        Souji::External::Command.json_lines(
          "docker", "system", "df", "--format", "{{json .}}",
          timeout: Souji::External::Command::SLOW_PROBE_TIMEOUT
        ).find { |row| row["Type"] == BUILD_CACHE_TYPE }
      end

      # `docker system df` reports what an unfiltered prune frees. With
      # `unused_for_days:` the prune frees only the subset unused that
      # long, which docker cannot tell us in advance -- so the figure
      # becomes an upper bound rather than a claim. Reporting it as
      # `size_bytes` would promise 8.7 GB and free nothing on a host whose
      # cache was all touched this week.
      def build_item(row, reclaimable, unused_for_days)
        filtered = !unused_for_days.nil?
        delegated_item(
          recipe: "docker-build-cache",
          key: "prune",
          argv: prune_argv(unused_for_days),
          reason: reason_for(row, unused_for_days),
          size_bytes: (reclaimable unless filtered),
          upper_bound_bytes: (reclaimable if filtered),
          size_basis: size_basis_for(filtered, unused_for_days),
          extra: {
            "record_count" => Integer(row["TotalCount"], exception: false),
            "total_bytes" => Souji::External::HumanSize.parse(row["Size"]),
            "unused_for_days" => unused_for_days
          }.merge(Souji::External::Docker.item_metadata)
        )
      end

      def size_basis_for(filtered, unused_for_days)
        basis = "docker system df: the Build Cache row's Reclaimable"
        return basis unless filtered

        "#{basis} (an upper bound: --filter unused-for=#{unused_for_days.to_i * 24}h " \
          "frees only the subset unused that long, which docker cannot report in advance)"
      end

      # Never -a: that would discard cache still in use.
      def prune_argv(unused_for_days)
        argv = %w[docker builder prune -f]
        return argv unless unused_for_days

        argv + ["--filter", "unused-for=#{unused_for_days.to_i * 24}h"]
      end

      def reason_for(row, unused_for_days)
        base = "#{row["TotalCount"]} buildkit cache records, of which #{row["Reclaimable"]} is reclaimable"
        return base unless unused_for_days

        "#{base}; only the records unused for #{unused_for_days} days are pruned"
      end
    end
  end
end
