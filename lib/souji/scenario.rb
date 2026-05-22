# frozen_string_literal: true

require "digest"
require "time"
require_relative "errors"
require_relative "dsl"
require_relative "plan"
require_relative "plan_item"
require_relative "recipe"
require_relative "version"

module Souji
  # A scenario file loaded from disk and ready to drive `souji plan`.
  #
  # The scenario file is evaluated with instance_eval against a fresh
  # Souji::DSL::Context (Trusted full Ruby per spec FR-005a). The
  # resulting context exposes the declared target_roots and recipe
  # invocations; `#run_plan` then probes each recipe's required external
  # commands (FR-020), calls `Recipe#enumerate`, and aggregates the items
  # into a Souji::Plan.
  class Scenario
    attr_reader :path, :content_sha256, :target_roots, :invocations

    def self.from_file(path)
      abs = File.expand_path(path)
      raise ScenarioNotFoundError, "scenario file not found: #{abs}" unless File.file?(abs)

      source = File.read(abs)
      sha = Digest::SHA256.hexdigest(source)
      context = DSL::Context.new(scenario_path: abs)
      begin
        context.evaluate!(source: source, filename: abs)
      rescue ScenarioError, UnknownRecipeError
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise unless e.is_a?(StandardError) || e.is_a?(ScriptError)

        raise ScenarioError, "failed to evaluate scenario #{abs}: #{e.class}: #{e.message}"
      end

      new(
        path: abs,
        content_sha256: sha,
        target_roots: context.target_roots,
        invocations: context.invocations
      )
    end

    def initialize(path:, content_sha256:, target_roots:, invocations:)
      @path = path
      @content_sha256 = content_sha256
      @target_roots = target_roots
      @invocations = invocations
    end

    def run_plan(now: Time.now, warn_io: $stderr)
      items = []
      @invocations.each do |invocation|
        recipe_class = Recipe.fetch(invocation.name)
        missing = missing_commands_for(recipe_class)
        if missing.any?
          warn_io.puts(
            "[souji] recipe #{invocation.name.inspect} skipped: " \
            "command #{missing.first.inspect} not found"
          )
          next
        end
        instance = recipe_class.new
        items.concat(instance.enumerate(invocation.targets, invocation.params))
      end

      Plan.new(
        souji_plan_version: Plan::SUPPORTED_VERSION,
        souji_version: Souji::VERSION,
        generated_at: now.iso8601,
        scenario_path: @path,
        scenario_content_sha256: @content_sha256,
        target_roots: @target_roots.dup,
        items: items
      )
    end

    private

    def missing_commands_for(recipe_class)
      recipe_class.required_external_commands.reject { |cmd| Recipe.available?(cmd) }
    end
  end
end
