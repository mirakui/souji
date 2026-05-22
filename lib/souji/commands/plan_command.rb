# frozen_string_literal: true

require_relative "../errors"
require_relative "../exit_codes"
require_relative "../paths"
require_relative "../plan"
require_relative "../recipes"
require_relative "../scenario"

module Souji
  module Commands
    # Orchestrates the `souji plan` subcommand.
    #
    # Inputs: a scenario argument (bare name or path-shaped, per FR-007a)
    # and an optional `-o` value (default per FR-007b).
    #
    # Output: a YAML plan file on disk and a one-line summary on stdout.
    # No filesystem mutation under target_roots (FR-008).
    class PlanCommand
      def initialize(stdout: $stdout, stderr: $stderr)
        @stdout = stdout
        @stderr = stderr
      end

      # Returns a Souji::ExitCodes::* value.
      def call(scenario_arg, output: nil, target_roots: [], quiet: false)
        Recipes.load_builtins!
        scenario_path = resolve_scenario_path(scenario_arg)
        return ExitCodes::USAGE_ERROR unless scenario_path

        scenario = Scenario.from_file(scenario_path)
        merge_extra_targets!(scenario, target_roots)

        plan = scenario.run_plan(warn_io: quiet ? StringIO.new : @stderr)
        write_plan_and_summarize(plan, scenario_arg, output)
        ExitCodes::SUCCESS
      rescue ScenarioError => e
        @stderr.puts("[souji] scenario error: #{e.message}")
        ExitCodes::SCENARIO_ERROR
      rescue UnknownRecipeError => e
        @stderr.puts("[souji] unknown recipe: #{e.message}")
        ExitCodes::SCENARIO_ERROR
      rescue StandardError => e
        @stderr.puts("[souji] unexpected error: #{e.class}: #{e.message}")
        @stderr.puts(e.backtrace.first(10).join("\n")) if ENV["SOUJI_DEBUG"]
        ExitCodes::UNEXPECTED
      end

      private

      def resolve_scenario_path(scenario_arg)
        Paths.resolve_scenario(scenario_arg)
      rescue ScenarioNotFoundError => e
        @stderr.puts("[souji] error: #{e.message}")
        nil
      end

      def write_plan_and_summarize(plan, scenario_arg, output)
        out_path = output ? expand_output_path(output) : Paths.default_plan_output_for(scenario_arg)
        Paths.ensure_cache_dir!
        FileUtils.mkdir_p(File.dirname(out_path))
        plan.dump_yaml(out_path)

        summary = plan.summary
        @stdout.puts(
          "wrote #{out_path}: #{summary[:total_count]} items across " \
          "#{summary[:by_recipe].size} recipes"
        )
      end

      def merge_extra_targets!(scenario, extra)
        return if extra.empty?

        extra.each do |t|
          path = File.expand_path(t)
          scenario.target_roots << path unless scenario.target_roots.include?(path)
        end
      end

      def expand_output_path(output)
        if Paths.path_shaped?(output)
          File.expand_path(output)
        else
          File.join(Paths.cache_dir, "#{output}#{Paths::PLAN_EXT}")
        end
      end
    end
  end
end
