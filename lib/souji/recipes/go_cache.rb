# frozen_string_literal: true

require_relative "../recipe"
require_relative "../fs_scan"
require_relative "../external/command"
require_relative "../external/delegated_prune"

module Souji
  module Recipes
    # Wipes go's build cache and/or module cache.
    #
    # This is the blunt member of the family and is treated as such. Unlike
    # `uv cache prune` or `pnpm store prune`, `go clean` does not remove
    # what is unreferenced -- it removes **everything**. So each half is
    # opt-in and both default off: a bare `recipe "go-cache"` proposes
    # nothing at all and says so, which means nobody can wipe a 3 GB
    # module cache by accident.
    #
    # The two halves are separate items because their costs are not
    # comparable. `go clean -cache` throws away compiled output: rebuilding
    # costs CPU and nothing else. `go clean -modcache` throws away
    # downloaded modules: rebuilding needs the network, and offline builds
    # stop working until it has run.
    #
    # One upside of the bluntness: because the whole directory goes, the
    # measured size is the real figure rather than an upper bound. It costs
    # a walk of the cache at plan time, which is a cost the scenario opted
    # into by naming the half it wants.
    class GoCache < Souji::Recipe
      include Souji::External::DelegatedPrune

      recipe_name "go-cache"
      required_external_commands "go"
      scope_free!
      description "Wipe go's build cache and/or module cache (opt-in: go clean -cache / -modcache)"
      param :build_cache, "Wipe GOCACHE with `go clean -cache`; costs only a rebuild (default: false)"
      param :mod_cache,
            "Wipe GOMODCACHE with `go clean -modcache`; forces a re-download of every module " \
            "and breaks offline builds (default: false)"

      HALVES = {
        build_cache: {
          key: "build-cache", env_var: "GOCACHE", flag: "-cache",
          reason: "go rebuilds its build cache from source; this costs CPU on the next build and nothing else"
        },
        mod_cache: {
          key: "mod-cache", env_var: "GOMODCACHE", flag: "-modcache",
          reason: "go re-downloads every module on the next build; this needs the network " \
                  "and offline builds stop working until it has"
        }
      }.freeze

      def enumerate(_target_roots, params)
        requested = HALVES.keys.select { |half| params[half] }
        if requested.empty?
          progress.note("go-cache proposes nothing unless build_cache: or mod_cache: is set")
          return []
        end

        dirs = cache_dirs
        requested.filter_map { |half| build_item(half, dirs[HALVES[half][:env_var]]) }
      end

      def verify(plan_item)
        verify_tool_and_cache_dir(plan_item)
      end

      def delete(plan_item)
        run_delegated(plan_item)
      end

      private

      # `go env` works outside a module, which matters: souji is not run
      # from the user's projects.
      def cache_dirs
        output = Souji::External::Command.capture("go", "env", "GOCACHE", "GOMODCACHE").to_s
        build, mod = output.lines.map(&:strip)
        { "GOCACHE" => presence(build), "GOMODCACHE" => presence(mod) }
      end

      def presence(value)
        value if value && !value.empty?
      end

      def build_item(half, dir)
        return nil unless dir && Dir.exist?(dir)

        spec = HALVES[half]
        progress.scanning("go #{spec[:env_var]} (#{dir})")
        delegated_item(
          recipe: "go-cache",
          key: spec[:key],
          argv: ["go", "clean", spec[:flag]],
          cache_dir: dir,
          reason: spec[:reason],
          # `go clean` removes the whole directory, so this is exact.
          size_bytes: Souji::FsScan.dir_size(dir),
          size_basis: "the whole #{spec[:env_var]}, which `go clean #{spec[:flag]}` removes entirely",
          extra: { "half" => spec[:key] }
        )
      end
    end
  end
end
