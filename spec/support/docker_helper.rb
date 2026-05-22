# frozen_string_literal: true

module Souji
  module SpecSupport
    # Helpers for the docker-image recipe's integration tests. The
    # docker-tagged tests are filter_run_excluding'd by default in
    # spec_helper.rb; pass WITH_DOCKER=1 to opt in.
    module DockerHelper
      def docker_available?
        system("command -v docker >/dev/null 2>&1") &&
          system("docker info >/dev/null 2>&1")
      end

      def requires_docker!
        skip "docker daemon not available" unless docker_available?
      end
    end
  end
end

RSpec.configure do |config|
  config.include Souji::SpecSupport::DockerHelper, :docker
end
