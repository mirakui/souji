# frozen_string_literal: true

require_relative "../action_log"
require_relative "../confirmation"
require_relative "../errors"
require_relative "../exit_codes"
require_relative "../paths"
require_relative "../plan"
require_relative "../recipe"
require_relative "../recipes"

module Souji
  module Commands
    # Orchestrates `souji apply`. Reads a plan, scope-checks every item,
    # bulk-confirms with the user, then runs Recipe#verify + Recipe#delete
    # per item, logging each outcome to stderr + (by default) a JSONL
    # file under $XDG_STATE_HOME/souji/log/.
    #
    # Apply MUST NOT load, parse, or hash the scenario file (FR-011a).
    # Apply MUST NOT call Recipe#enumerate.
    class ApplyCommand
      def initialize(stdout: $stdout, stderr: $stderr, stdin: $stdin)
        @stdout = stdout
        @stderr = stderr
        @stdin = stdin
      end

      def call(plan_arg, yes: false, dry_run: false, log_file: nil, no_log_file: false)
        return usage_error("--log-file and --no-log-file are mutually exclusive") if log_file && no_log_file

        Recipes.load_builtins!
        plan_path = resolve_plan_path(plan_arg)
        return ExitCodes::USAGE_ERROR unless plan_path

        plan = load_plan(plan_path)
        return ExitCodes::PLAN_ERROR unless plan

        decision = confirm(plan, plan_path, yes: yes, dry_run: dry_run)
        return ExitCodes::USER_CANCELLED if decision == :cancel

        execute(plan, plan_path, dry_run: dry_run, log_file: log_file, no_log_file: no_log_file)
      rescue StandardError => e
        @stderr.puts("[souji] unexpected error: #{e.class}: #{e.message}")
        @stderr.puts(e.backtrace.first(10).join("\n")) if ENV["SOUJI_DEBUG"]
        ExitCodes::UNEXPECTED
      end

      private

      def resolve_plan_path(plan_arg)
        Paths.resolve_plan(plan_arg)
      rescue PlanNotFoundError => e
        @stderr.puts("[souji] error: #{e.message}")
        nil
      end

      def load_plan(plan_path)
        Plan.load_yaml(plan_path)
      rescue IncompatiblePlanError, ScopeViolationError => e
        @stderr.puts("[souji] plan error: #{e.message}")
        nil
      end

      def confirm(plan, plan_path, yes:, dry_run:)
        @stdout.puts(format_prompt_header(plan, plan_path))
        Confirmation.ask(
          prompt: "Proceed?",
          stdin: @stdin, stdout: @stdout, yes: yes, dry_run: dry_run
        )
      end

      def format_prompt_header(plan, plan_path)
        summary = plan.summary
        lines = ["Souji plan: #{plan_path}"]
        bytes_h = humanize_bytes(summary[:total_bytes])
        lines << "About to delete #{summary[:total_count]} items (estimated #{bytes_h}):"
        summary[:by_recipe].sort_by { |k, _| k }.each do |recipe, info|
          lines << format("  - %-22<recipe>s %<count>d items", recipe: "#{recipe}:", count: info[:count])
        end
        lines.join("\n")
      end

      def execute(plan, plan_path, dry_run:, log_file:, no_log_file:)
        log = ActionLog.new(plan_path: plan_path, log_file_override: log_file,
                            no_log_file: no_log_file, stderr: @stderr)
        plan.items.each { |item| process_item(item, log, dry_run: dry_run) }
        log.summary
        log.close

        log.failures? ? ExitCodes::APPLY_PARTIAL : ExitCodes::SUCCESS
      end

      def process_item(item, log, dry_run:)
        recipe_class = fetch_recipe_class(item.recipe, log, item)
        return unless recipe_class

        recipe = recipe_class.new
        started = Time.now
        verdict = safe_verify(recipe, item)
        if verdict.is_a?(Array) && verdict.first == :skip
          log.record(item: item, outcome: :skipped,
                     duration_ms: elapsed_ms(started), reason: verdict[1])
          return
        end

        if dry_run
          log.record(item: item, outcome: :skipped,
                     duration_ms: elapsed_ms(started), reason: "dry-run")
          return
        end

        outcome = safe_delete(recipe, item)
        finalize_item(item, log, outcome, started)
      end

      def fetch_recipe_class(name, log, item)
        Recipe.fetch(name)
      rescue UnknownRecipeError => e
        log.record(item: item, outcome: :failed, duration_ms: 0, error: e.message)
        nil
      end

      def safe_verify(recipe, item)
        recipe.verify(item)
      rescue StandardError => e
        [:skip, "verify raised: #{e.class}: #{e.message}"]
      end

      def safe_delete(recipe, item)
        recipe.delete(item)
      rescue StandardError => e
        [:failed, "#{e.class}: #{e.message}"]
      end

      def finalize_item(item, log, outcome, started)
        case outcome
        when :deleted, :trashed
          log.record(item: item, outcome: outcome, duration_ms: elapsed_ms(started))
        when Array
          if outcome.first == :failed
            log.record(item: item, outcome: :failed, duration_ms: elapsed_ms(started),
                       error: outcome[1])
          else
            log.record(item: item, outcome: :skipped, duration_ms: elapsed_ms(started),
                       reason: outcome[1])
          end
        else
          log.record(item: item, outcome: :failed, duration_ms: elapsed_ms(started),
                     error: "unexpected delete return: #{outcome.inspect}")
        end
      end

      def elapsed_ms(started)
        ((Time.now - started) * 1000).to_i
      end

      def humanize_bytes(bytes)
        return "0 B" if bytes.zero?

        units = %w[B KB MB GB TB]
        value = bytes.to_f
        idx = 0
        while value >= 1024 && idx < units.size - 1
          value /= 1024
          idx += 1
        end
        format("%<value>.1f %<unit>s", value: value, unit: units[idx])
      end

      def usage_error(message)
        @stderr.puts("[souji] usage error: #{message}")
        ExitCodes::USAGE_ERROR
      end
    end
  end
end
