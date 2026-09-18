# frozen_string_literal: true

require_relative "../recipe"
require_relative "../fs_scan"
require_relative "../external/command"
require_relative "../external/delegated_prune"

module Souji
  module Recipes
    # Removes the mise-managed tool versions that no configuration mise
    # knows about still references.
    #
    # This is the one member of the delegated-prune family that gets
    # souji's full treatment, because mise is the one tool that can both
    # enumerate its prunable units (`mise ls --prunable --json`) and remove
    # exactly one of them (`mise uninstall <tool>@<version>`). So: one item
    # per version, with its own measured size, its own reason and its own
    # re-verification.
    #
    # That re-verification is the most load-bearing in the whole family.
    # What counts as "prunable" depends on which `.tool-versions` and
    # `mise.toml` files mise has tracked -- which is *not* the same as the
    # scenario's target roots, and which changes the moment the user opens
    # an old project. A version that stops being prunable between plan and
    # apply has been legitimately reclaimed by its project, and `#verify`
    # is what notices.
    #
    # `mise prune --dry-run` is deliberately not used: it rewrites mise's
    # tracked-configs state, so it is not a read-only probe and has no
    # place in `souji plan`.
    class MiseVersion < Souji::Recipe
      include Souji::External::DelegatedPrune

      recipe_name "mise-version"
      required_external_commands "mise"
      scope_free!
      description "Remove mise tool versions no tracked config references (mise ls --prunable)"
      param :tools, "Only propose versions of these tools (default: every prunable tool)"

      def enumerate(_target_roots, params)
        wanted = tool_filter(params[:tools])
        prunable_versions
          .select { |entry| wanted.nil? || wanted.include?(entry[:tool]) }
          .map { |entry| build_item(entry) }
      end

      def verify(plan_item)
        shared = verify_tool_and_cache_dir(plan_item)
        return shared unless shared == :ok

        tool = plan_item.metadata["tool"]
        version = plan_item.metadata["version"]
        return :ok if still_prunable?(tool, version)

        [:skip, "#{tool}@#{version} is no longer prunable (a tracked config now references it)"]
      end

      def delete(plan_item)
        run_delegated(plan_item)
      end

      private

      def tool_filter(tools)
        return nil if tools.nil?

        Array(tools).map(&:to_s)
      end

      # mise writes WARN lines to stderr; the JSON is on stdout, and
      # External::Command.capture returns stdout only.
      def prunable_map
        progress.scanning("mise prunable versions")
        Souji::External::Command.json("mise", "ls", "--prunable", "--json") || {}
      end

      def prunable_versions(map = prunable_map)
        found = map.flat_map { |tool, entries| installed_entries(tool, entries) }
        found.sort_by { |entry| [entry[:tool], entry[:version]] }
      end

      def installed_entries(tool, entries)
        Array(entries).filter_map do |entry|
          # `installed: false` means mise knows of the version but has
          # nothing on disk for it -- there is nothing to reclaim.
          next unless entry["installed"] && entry["install_path"]

          { tool: tool, version: entry["version"].to_s, install_path: entry["install_path"] }
        end
      end

      def still_prunable?(tool, version)
        prunable_versions.any? { |entry| entry[:tool] == tool && entry[:version] == version }
      end

      def build_item(entry)
        spec = "#{entry[:tool]}@#{entry[:version]}"
        delegated_item(
          recipe: "mise-version",
          key: spec,
          argv: ["mise", "uninstall", spec],
          cache_dir: entry[:install_path],
          reason: "No tracked mise config references #{spec}",
          # The install directory goes in its entirety, so this is exact.
          size_bytes: Souji::FsScan.dir_size(entry[:install_path]),
          size_basis: "the whole install directory, which `mise uninstall` removes",
          extra: { "tool" => entry[:tool], "version" => entry[:version],
                   "install_path" => entry[:install_path] }
        )
      end
    end
  end
end
