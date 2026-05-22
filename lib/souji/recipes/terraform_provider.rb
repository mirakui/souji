# frozen_string_literal: true

require "find"
require_relative "../recipe"
require_relative "../plan_item"

module Souji
  module Recipes
    # Identifies terraform provider versions cached under
    # ~/.terraform.d/plugin-cache/ (or wherever $TF_PLUGIN_CACHE_DIR
    # points) that are NOT referenced by any .terraform.lock.hcl file
    # under the scenario's target_roots.
    #
    # No external command is required; the recipe walks the filesystem
    # and parses lockfiles line-by-line (the structure we care about is
    # simple enough to avoid pulling in an HCL gem).
    class TerraformProvider < Souji::Recipe
      recipe_name "terraform-provider"
      description "Remove cached terraform provider versions unreferenced by any .terraform.lock.hcl under scope"

      LOCK_PROVIDER_HEADER = /\Aprovider\s+"([^"]+)"\s*\{\s*\z/
      LOCK_VERSION = /\A\s*version\s*=\s*"([^"]+)"/

      def enumerate(target_roots, params)
        plugin_cache_dir = resolve_plugin_cache_dir(params)
        return [] unless plugin_cache_dir && Dir.exist?(plugin_cache_dir)

        referenced = collect_referenced(target_roots)
        cache_entries = collect_cache_entries(plugin_cache_dir).sort_by { |e| e[:path] }
        cache_entries.reject { |entry| referenced.include?([entry[:address], entry[:version]]) }
                     .map { |entry| build_plan_item(entry) }
      end

      def verify(plan_item)
        return [:skip, "cache entry already removed"] unless Dir.exist?(plan_item.path)

        # We do NOT re-scan target_roots here because the scenario file
        # is no longer consulted at apply time (FR-011a). If the user
        # reinstalled the provider after plan generation, that is fine —
        # we just confirm the directory still exists; per-item recipe
        # verification's scope is the resource's own state.
        :ok
      end

      def delete(plan_item)
        require_relative "../trash"
        Souji::Trash.dispose(plan_item.path)
      rescue StandardError => e
        [:failed, e.message]
      end

      private

      def resolve_plugin_cache_dir(params)
        params[:plugin_cache_dir] ||
          ENV["TF_PLUGIN_CACHE_DIR"] ||
          File.expand_path("~/.terraform.d/plugin-cache")
      end

      def collect_referenced(target_roots)
        refs = []
        target_roots.each do |root|
          next unless Dir.exist?(root)

          Find.find(root) do |path|
            next unless File.file?(path) && File.basename(path) == ".terraform.lock.hcl"

            refs.concat(parse_lockfile(path))
          rescue Errno::EACCES, Errno::ENOENT
            next
          end
        end
        refs.to_set
      end

      def parse_lockfile(path)
        refs = []
        current_address = nil
        File.foreach(path) do |line|
          if (m = line.match(LOCK_PROVIDER_HEADER))
            current_address = m[1]
          elsif current_address && (m = line.match(LOCK_VERSION))
            refs << [current_address, m[1]]
            current_address = nil
          end
        end
        refs
      end

      def collect_cache_entries(plugin_cache_dir)
        entries = []
        Dir.glob(File.join(plugin_cache_dir, "*", "*", "*", "*", "*")).each do |path|
          next unless File.directory?(path)

          rel = path.delete_prefix("#{plugin_cache_dir}/").split("/")
          next unless rel.size == 5

          hostname, namespace, provider, version, _os_arch = rel
          entries << {
            path: path,
            address: "#{hostname}/#{namespace}/#{provider}",
            namespace: namespace,
            provider: provider,
            version: version
          }
        end
        entries
      end

      def build_plan_item(entry)
        Souji::PlanItem.new(
          id: Souji::PlanItem.generate_id("terraform-provider"),
          recipe: "terraform-provider",
          path: entry[:path],
          reason: "Provider version unreferenced by any .terraform.lock.hcl under target roots",
          size_bytes: dir_size(entry[:path]),
          metadata: {
            "namespace" => entry[:namespace],
            "provider" => entry[:provider],
            "version" => entry[:version]
          }
        )
      end

      def dir_size(path)
        total = 0
        Find.find(path) do |p|
          total += File.size(p) if File.file?(p)
        rescue Errno::EACCES, Errno::ENOENT
          next
        end
        total
      end
    end
  end
end
