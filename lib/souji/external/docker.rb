# frozen_string_literal: true

require "rbconfig"
require_relative "command"

module Souji
  module External
    # Facts about the docker daemon the recipes need to report honestly.
    #
    # The one that matters: on macOS the daemon runs inside a Linux VM
    # (Rancher Desktop, Docker Desktop, colima), and pruning inside that VM
    # does not shrink the VM's sparse disk image. The space is reclaimed
    # *inside* the VM and the host's `df` does not move. souji's whole
    # value proposition is a byte count, so reporting VM bytes as host
    # bytes would be a lie -- and `docker-image` was telling it.
    module Docker
      module_function

      # Memoized per process: `docker info` is a round trip to the daemon,
      # and three recipes ask the same question in one plan run.
      def info
        return @info if defined?(@info)

        @info = Command.json("docker", "info", "--format", "{{json .}}",
                             timeout: Command::PROBE_TIMEOUT)
      end

      def reset!
        remove_instance_variable(:@info) if defined?(@info)
      end

      # True when reclaimed space lands inside a VM disk image rather than
      # on the host filesystem. A Linux daemon on a non-Linux host is
      # exactly that situation, whichever product provides the VM.
      def vm?
        return false if RbConfig::CONFIG["host_os"].match?(/linux/)

        info&.fetch("OSType", nil) == "linux"
      end

      def daemon_name
        info&.fetch("Name", nil)
      end

      def daemon_os
        info&.fetch("OperatingSystem", nil)
      end

      # Metadata every docker recipe's items carry, so Plan#summary can
      # keep VM bytes out of the host total.
      def item_metadata
        return {} unless vm?

        { "host_space_unaffected" => true, "daemon_host" => daemon_name,
          "daemon_os" => daemon_os }.compact
      end

      def vm_note
        return nil unless vm?

        "docker daemon runs in a VM (#{[daemon_name, daemon_os].compact.join(" / ")}); " \
          "reclaimed space stays inside the VM disk image and does not free host disk"
      end
    end
  end
end
