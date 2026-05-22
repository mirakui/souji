# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  add_filter "/spec/"
  minimum_coverage 80 if ENV["COVERAGE_GATE"] == "1"
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "souji"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = false

  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand(config.seed)

  config.filter_run_excluding(:docker) unless ENV["WITH_DOCKER"] == "1"
  config.filter_run_excluding(:terraform) unless ENV["WITH_TERRAFORM"] == "1"
  config.filter_run_excluding(:git) if ENV["WITHOUT_GIT"] == "1"
end
