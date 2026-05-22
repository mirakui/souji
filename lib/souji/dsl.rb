# frozen_string_literal: true

require_relative "errors"

module Souji
  module DSL
    # A single `recipe(...)` invocation captured during scenario
    # evaluation. The DSL produces an ordered list of these for
    # Souji::Scenario#run_plan to act on.
    RecipeInvocation = Data.define(:name, :targets, :params)

    # The object that hosts the DSL methods (`target`, `recipe`,
    # `with_targets`). A fresh instance is created for each scenario
    # evaluation; the scenario file is `instance_eval`'d against it.
    #
    # All Ruby language constructs are available inside a scenario
    # (loops, helpers, `require`); the DSL adds these methods as
    # additional vocabulary, but does NOT sandbox anything. See spec
    # FR-005a (Trusted full Ruby).
    class Context
      attr_reader :scenario_path, :target_roots, :invocations

      def initialize(scenario_path:)
        @scenario_path = scenario_path
        @scenario_dir = File.dirname(scenario_path)
        @target_roots = []
        @invocations = []
        @scope_stack = []
      end

      def target(*paths)
        paths.each do |raw|
          expanded = expand_path(raw)
          @target_roots << expanded unless @target_roots.include?(expanded)
        end
      end

      def recipe(name, targets: nil, **params)
        resolved_targets = resolve_targets(targets)
        @invocations << RecipeInvocation.new(name: name.to_s, targets: resolved_targets, params: params)
      end

      def with_targets(*paths)
        scoped = paths.map { |p| expand_path(p) }
        scoped.each { |p| ensure_within_scope!(p) }
        @scope_stack.push(scoped)
        yield
      ensure
        @scope_stack.pop
      end

      def evaluate!(source:, filename:)
        instance_eval(source, filename, 1)
      end

      private

      def resolve_targets(explicit)
        return current_scope if explicit.nil?

        candidates = Array(explicit).map { |p| expand_path(p) }
        candidates.each { |c| ensure_within_scope!(c) }
        candidates
      end

      def current_scope
        return @scope_stack.last.dup unless @scope_stack.empty?

        @target_roots.dup
      end

      def ensure_within_scope!(path)
        roots = @scope_stack.empty? ? @target_roots : @scope_stack.last
        return if roots.empty? # nothing declared yet — scope check happens later
        return if within_any?(path, roots)

        raise ScenarioError,
              "target #{path.inspect} escapes the declared scope (#{roots.join(", ")})"
      end

      def within_any?(path, roots)
        roots.any? do |root|
          path == root || path.start_with?("#{root}/")
        end
      end

      def expand_path(raw)
        if raw.is_a?(String) && raw.start_with?("/")
          raw
        elsif raw.is_a?(String) && raw.start_with?("~")
          File.expand_path(raw)
        else
          File.expand_path(raw.to_s, @scenario_dir)
        end
      end
    end
  end
end
