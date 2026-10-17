# frozen_string_literal: true

require "time"
require_relative "../recipe"
require_relative "../plan_item"
require_relative "../external/command"
require_relative "../external/human_size"
require_relative "../external/docker"

module Souji
  module Recipes
    # Identifies dangling docker images (`<none>:<none>`, no tag) and
    # proposes them for removal via `docker image rm`.
    #
    # Docker images are not trashable — `docker image rm` is the only
    # native deletion mechanism — so the outcome from apply is :deleted
    # (not :trashed), recorded in the item's metadata.irreversible flag.
    #
    # This subsumes the `docker image prune -f` a hand-written cleanup
    # would run, and improves on it: one item per image with its own size,
    # and per-item re-verification that the image is still present and
    # still untagged before anything is removed.
    #
    # "Dangling" in docker's own vocabulary means only "untagged": an
    # untagged image that a stopped or never-started container was created
    # from is still listed by `--filter dangling=true`, and `docker image
    # rm` refuses it with a conflict. `docker image prune` silently skips
    # those; souji does the same, by excluding every image any container
    # -- in any state, hence `docker ps -a` -- was created from. Such an
    # image becomes a candidate on the first plan after the container is
    # gone, which keeps this recipe independent of whether docker-container
    # is in the same scenario or where it is declared.
    class DockerImage < Souji::Recipe
      recipe_name "docker-image"
      required_external_commands "docker"
      scope_free!
      description "Remove dangling docker images (no tag, no container ancestry)"
      param :older_than_days, "Only propose images created at least this many days ago (default: no age filter)"

      # docker's wording for "a container still references this image".
      IN_USE_CONFLICT_RE = /conflict: unable to (?:delete|remove).*(?:being used by|in use by)/i

      def enumerate(_target_roots, params)
        older_than_days = params[:older_than_days]
        Souji::External::Docker.note_vm(progress)
        dangling = list_dangling
        return [] if dangling.empty?

        in_use = container_image_ids
        return [] unless in_use

        dangling.reject { |img| in_use.include?(img[:id]) }
                .select { |img| matches_age_filter?(img, older_than_days) }
                .sort_by { |img| img[:id] }
                .map { |img| build_plan_item(img) }
      end

      def verify(plan_item)
        id = image_id(plan_item)
        return [:skip, "image no longer present"] unless image_present?(id)
        return [:skip, "image is now tagged"] unless image_dangling?(id)

        container_reason = container_use_reason(id)
        return [:skip, container_reason] if container_reason

        :ok
      end

      def delete(plan_item)
        result = Souji::External::Command.run("docker", "image", "rm", image_id(plan_item),
                                              timeout: Souji::External::Command::PRUNE_TIMEOUT)
        return :deleted if result.success?
        return [:failed, "docker image rm timed out"] if result.timed_out

        stderr = result.stderr.strip
        # A container created from the image between verify and here. That
        # is the race verify exists to narrow, not an error in the image.
        return [:skip, "image is in use by a container: #{stderr}"] if stderr.match?(IN_USE_CONFLICT_RE)

        [:failed, "docker image rm failed: #{stderr}"]
      end

      private

      def image_id(plan_item)
        plan_item.metadata["image_id"] || plan_item.path.delete_prefix("docker-image://")
      end

      def list_dangling
        progress.scanning("docker images (dangling=true)")
        Souji::External::Command.json_lines(
          "docker", "image", "ls", "--filter", "dangling=true",
          "--format", "{{json .}}", "--no-trunc"
        ).map do |obj|
          { id: obj["ID"], size_human: obj["Size"], created_at: parse_created_at(obj["CreatedAt"]) }
        end
      end

      # The full image ID of every container, whatever its state. nil when
      # docker cannot answer: an image whose ancestry souji could not check
      # is not one it may call dangling, so the plan proposes none.
      def container_image_ids
        progress.scanning("docker containers (all states, for image ancestry)")
        ids = run_probe("docker", "ps", "-a", "-q", "--no-trunc")
        return nil unless ids

        container_ids = ids.split
        return Set.new if container_ids.empty?

        images = run_probe("docker", "container", "inspect", "--format", "{{.Image}}", *container_ids)
        images && Set.new(images.split)
      end

      def run_probe(*argv)
        result = Souji::External::Command.run(*argv, timeout: Souji::External::Command::SLOW_PROBE_TIMEOUT)
        return result.stdout if result.success?

        reason = result.timed_out ? "timed out" : "failed: #{result.stderr.strip}"
        progress.note("#{argv.first(3).join(" ")} #{reason}; cannot rule out container ancestry, " \
                      "proposing no images")
        nil
      end

      # `ancestor=` matches containers created from the image or from any
      # image built on it, which is exactly the set `docker image rm`
      # would refuse over.
      def container_use_reason(id)
        result = Souji::External::Command.run("docker", "ps", "-a", "-q", "--no-trunc",
                                              "--filter", "ancestor=#{id}")
        return "could not check container ancestry: #{probe_failure(result)}" unless result.success?

        users = result.stdout.split
        return nil if users.empty?

        "image is used by #{users.size} container(s) (#{users.map { |c| c[0, 12] }.join(", ")})"
      end

      def probe_failure(result)
        result.timed_out ? "docker ps timed out" : result.stderr.strip
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
          # docker prints SI units, so kB is 1000. Reading them as binary
          # overstated every image by about 7% at GB scale.
          size_bytes: Souji::External::HumanSize.parse(img[:size_human]),
          metadata: {
            "image_id" => img[:id],
            "created_at" => img[:created_at]&.utc&.iso8601,
            "irreversible" => true,
            "scope_free" => true
          }.merge(Souji::External::Docker.item_metadata).compact
        )
      end

      def image_present?(id)
        Souji::External::Command.ok?("docker", "image", "inspect", id)
      end

      def image_dangling?(id)
        tags = Souji::External::Command.json(
          "docker", "image", "inspect", "--format", "{{json .RepoTags}}", id
        )
        return false unless tags.is_a?(Array)

        # Dangling = empty repo tags (or only `<none>`)
        tags.empty? || tags.all? { |tag| tag.start_with?("<none>") }
      end
    end
  end
end
