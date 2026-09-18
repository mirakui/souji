# frozen_string_literal: true

require "rbconfig"
require "souji/recipe"

module Souji
  module SpecSupport
    # Skips a tag-gated integration example when the tool it drives is not
    # installed, mirroring requires_docker! in docker_helper.rb.
    module ToolHelper
      def requires_tool!(command)
        skip("#{command} is not installed") unless Souji::Recipe.available?(command)
      end

      # Whether reclaimed docker space lands on the host or inside a VM
      # depends on the host OS, so the branch is unreachable from a single
      # machine without saying which host we are pretending to be.
      def stub_host_os(value)
        allow(RbConfig::CONFIG).to receive(:[]).and_call_original
        allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return(value)
      end
    end
  end
end

RSpec.configure do |config|
  config.include Souji::SpecSupport::ToolHelper
end
