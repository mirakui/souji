# frozen_string_literal: true

require "json"
require "open3"
require "time"
require_relative "../recipe"
require_relative "../plan_item"

module Souji
  module Recipes
    # Identifies dangling docker images (`<none>:<none>`, no tag) and
    # proposes them for removal via `docker image rm`.
    #
    # Docker images are not trashable — `docker image rm` is the only
    # native deletion mechanism — so the resulting outcome from
    # apply is :deleted (not :trashed). This is recorded in the
    # PlanItem's metadata.irreversible flag.
    class DockerImage < Souji::Recipe
      recipe_name "docker-image"
      required_external_commands "docker"
      description "Remove dangling docker images (no tag, no container ancestry)"

      def enumerate(_target_roots, params)
        older_than_days = params[:older_than_days]
        list_dangling.select { |img| matches_age_filter?(img, older_than_days) }.sort_by { |img| img[:id] }.map do |img|
          build_plan_item(img)
        end
      end

      def verify(plan_item)
        id = plan_item.metadata["image_id"] || plan_item.path.delete_prefix("docker-image://")
        return [:skip, "image no longer present"] unless image_present?(id)
        return [:skip, "image is now tagged"] unless image_dangling?(id)

        :ok
      end

      def delete(plan_item)
        id = plan_item.metadata["image_id"] || plan_item.path.delete_prefix("docker-image://")
        _stdout, stderr, status = Open3.capture3("docker", "image", "rm", id)
        return :deleted if status.success?

        [:failed, "docker image rm failed: #{stderr.strip}"]
      end

      private

      def list_dangling
        stdout, _stderr, status = Open3.capture3(
          "docker", "image", "ls", "--filter", "dangling=true",
          "--format", "{{json .}}", "--no-trunc"
        )
        return [] unless status.success?

        stdout.each_line.filter_map do |line|
          obj = JSON.parse(line)
          {
            id: obj["ID"],
            size_human: obj["Size"],
            created_at: parse_created_at(obj["CreatedAt"]),
            raw_size: obj["Size"]
          }
        rescue JSON::ParserError
          nil
        end
      end

      def parse_created_at(text)
        return nil unless text

        Time.parse(text)
      rescue ArgumentError
        nil
      end

      def matches_age_filter?(img, older_than_days)
        return true unless older_than_days

        created_at = img[:created_at]
        return false unless created_at

        (Time.now - created_at) >= (older_than_days * 86_400)
      end

      def build_plan_item(img)
        Souji::PlanItem.new(
          id: Souji::PlanItem.generate_id("docker-image"),
          recipe: "docker-image",
          path: "docker-image://#{img[:id]}",
          reason: "Dangling image (no tag, no container ancestry)",
          size_bytes: parse_size_bytes(img[:size_human]),
          metadata: {
            "image_id" => img[:id],
            "created_at" => img[:created_at]&.utc&.iso8601,
            "irreversible" => true
          }.compact
        )
      end

      def parse_size_bytes(human)
        return nil unless human

        m = human.match(/\A([0-9.]+)\s*([KMGT]?B)\z/i)
        return nil unless m

        units = { "B" => 1, "KB" => 1024, "MB" => 1024**2, "GB" => 1024**3, "TB" => 1024**4 }
        (m[1].to_f * units.fetch(m[2].upcase)).to_i
      end

      def image_present?(id)
        _stdout, _stderr, status = Open3.capture3("docker", "image", "inspect", id)
        status.success?
      end

      def image_dangling?(id)
        stdout, _stderr, status = Open3.capture3(
          "docker", "image", "inspect", "--format", "{{json .RepoTags}}", id
        )
        return false unless status.success?

        # Dangling = empty repo tags (or only `<none>`)
        tags = JSON.parse(stdout.strip)
        tags.empty? || tags.all? { |t| t.start_with?("<none>") }
      rescue JSON::ParserError
        false
      end
    end
  end
end
