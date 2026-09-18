# frozen_string_literal: true

require "time"
require_relative "../recipe"
require_relative "../plan_item"
require_relative "../external/command"
require_relative "../external/human_size"
require_relative "../external/docker"

module Souji
  module Recipes
    # Removes containers that have stopped for good: exited, created but
    # never started, or dead.
    #
    # One item per container, which is strictly better than the
    # `docker container prune -f` a hand-written cleanup would run: each
    # container gets its own size, its own reason, and its own
    # re-verification immediately before removal.
    #
    # Running containers can never be proposed, by three independent
    # mechanisms:
    #
    # 1. the listing filters to terminal states, and the result is filtered
    #    again in Ruby, so a docker release that loosened its filter
    #    semantics still could not surface one;
    # 2. `#verify` re-inspects the container's state immediately before
    #    removal, which is what catches a `docker compose up` between plan
    #    and apply;
    # 3. `docker rm` is run without `-f`, so even losing that race fails
    #    loudly instead of killing something that is working.
    #
    # `-v` is likewise never passed. A container's volumes may hold the
    # only copy of a database's data directory, and removing a container is
    # not consent to remove its data.
    class DockerContainer < Souji::Recipe
      recipe_name "docker-container"
      required_external_commands "docker"
      scope_free!
      description "Remove stopped, created and dead docker containers"
      param :older_than_days,
            "Only propose containers created at least this many days ago (default: no age filter)"

      TERMINAL_STATES = %w[exited created dead].freeze

      def enumerate(_target_roots, params)
        Souji::External::Docker.note_vm(progress)
        terminal_containers
          .select { |container| matches_age_filter?(container, params[:older_than_days]) }
          .sort_by { |container| container[:id] }
          .map { |container| build_item(container) }
      end

      def verify(plan_item)
        id = plan_item.metadata["container_id"]
        result = Souji::External::Command.run("docker", "container", "inspect",
                                              "--format", "{{.State.Status}}", id)
        # A stopped daemon or a timed-out inspect is not the same fact as
        # "the container is gone", and reporting it as such would put
        # something souji did not observe into the action log.
        return [:skip, "docker container inspect timed out"] if result.timed_out
        return [:skip, container_absence_reason(result)] unless result.success?

        state = result.stdout.strip
        return [:skip, "container is now #{state}"] unless TERMINAL_STATES.include?(state)

        :ok
      end

      def delete(plan_item)
        # No -f: a container that started since planning must fail here
        # rather than be killed. No -v: its volumes are not ours.
        result = Souji::External::Command.run("docker", "rm", plan_item.metadata["container_id"],
                                              timeout: Souji::External::Command::PRUNE_TIMEOUT)
        return :deleted if result.success?
        return [:failed, "docker rm timed out"] if result.timed_out

        [:failed, "docker rm failed: #{result.stderr.strip}"]
      end

      private

      # `docker ps --size` makes the daemon compute every container's
      # writable-layer diff, which is the same kind of tree walk
      # `docker system df` gets the slow budget for. Under the default
      # probe timeout a busy host would silently yield an empty plan.
      def terminal_containers
        progress.scanning("docker containers (#{TERMINAL_STATES.join(", ")})")
        result = Souji::External::Command.run(*list_argv,
                                              timeout: Souji::External::Command::SLOW_PROBE_TIMEOUT)
        return note_failed_probe(result) unless result.success?

        Souji::External::Command.parse_json_lines(result.stdout)
                                .select { |obj| TERMINAL_STATES.include?(obj["State"]) }
                                .map { |obj| parse_container(obj) }
      end

      # An empty result and a failed probe look identical in a plan, so the
      # difference goes on stderr rather than being swallowed.
      def note_failed_probe(result)
        reason = result.timed_out ? "timed out" : "failed: #{result.stderr.strip}"
        progress.note("docker ps #{reason}; proposing no containers")
        []
      end

      def container_absence_reason(result)
        stderr = result.stderr.to_s
        return "docker is not answering: #{stderr.strip}" unless stderr.empty? || stderr.match?(/[Nn]o such/)

        "container no longer present"
      end

      def list_argv
        state_filters = TERMINAL_STATES.flat_map { |state| ["--filter", "status=#{state}"] }
        ["docker", "ps", "-a", *state_filters, "--no-trunc", "--size", "--format", "{{json .}}"]
      end

      def parse_container(obj)
        {
          id: obj["ID"], name: obj["Names"], image: obj["Image"], state: obj["State"],
          status: obj["Status"], size: obj["Size"], created_at: parse_time(obj["CreatedAt"])
        }
      end

      def parse_time(text)
        return nil unless text

        Time.parse(text)
      rescue ArgumentError
        nil
      end

      def matches_age_filter?(container, older_than_days)
        return true unless older_than_days

        created_at = container[:created_at]
        return false unless created_at

        (Time.now - created_at) >= (older_than_days * 86_400)
      end

      def build_item(container)
        writable, virtual = parse_sizes(container[:size])
        Souji::PlanItem.new(
          id: Souji::PlanItem.generate_id("docker-container"),
          recipe: "docker-container",
          path: "docker-container://#{container[:id]}",
          reason: reason_for(container, virtual),
          size_bytes: writable,
          metadata: metadata_for(container, virtual)
        )
      end

      # docker reports `"625kB (virtual 45.7MB)"`. Only the leading figure
      # -- the writable layer -- is freed by `docker rm`; the virtual size
      # is shared with the image. Reading the wrong one overstates a
      # typical stopped container by a factor of several hundred.
      def parse_sizes(text)
        Souji::External::HumanSize.parse_all(text).first(2)
      end

      def reason_for(container, virtual)
        base = "Container #{container[:name]} is #{container[:state]} (#{container[:status]})"
        return base unless virtual

        "#{base}; only its writable layer is freed, the image layers are shared"
      end

      def metadata_for(container, virtual)
        {
          "container_id" => container[:id],
          "name" => container[:name],
          "image" => container[:image],
          "state" => container[:state],
          "created_at" => container[:created_at]&.utc&.iso8601,
          "virtual_size_bytes" => virtual,
          "irreversible" => true,
          "scope_free" => true
        }.merge(Souji::External::Docker.item_metadata).compact
      end
    end
  end
end
