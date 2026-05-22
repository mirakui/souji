# frozen_string_literal: true

require "fileutils"
require_relative "errors"

module Souji
  # XDG Base Directory resolver. Implements the name-resolution rules in
  # spec FR-007a / FR-007b / FR-017a:
  #
  # - Path-shaped arguments (contains "/", starts with "~", or ends with
  #   .rb / .soujiplan) → treated as filesystem paths.
  # - Bare names → looked up under $XDG_CONFIG_HOME/souji/scenario/ for
  #   scenarios and $XDG_CACHE_HOME/souji/ for plans.
  # - Action log default destination is under $XDG_STATE_HOME/souji/log/.
  #
  # Cache and state directories are created on demand; the scenario
  # directory is NEVER auto-created (per spec FR-007b).
  module Paths
    module_function

    SCENARIO_EXT = ".rb"
    PLAN_EXT = ".soujiplan"

    def path_shaped?(arg)
      return false if arg.nil? || arg.empty?

      arg.include?("/") ||
        arg.start_with?("~") ||
        arg.end_with?(SCENARIO_EXT) ||
        arg.end_with?(PLAN_EXT)
    end

    def config_home
      ENV["XDG_CONFIG_HOME"].then { |v| v.nil? || v.empty? ? File.join(Dir.home, ".config") : v }
    end

    def cache_home
      ENV["XDG_CACHE_HOME"].then { |v| v.nil? || v.empty? ? File.join(Dir.home, ".cache") : v }
    end

    def state_home
      ENV["XDG_STATE_HOME"].then { |v| v.nil? || v.empty? ? File.join(Dir.home, ".local", "state") : v }
    end

    def scenario_dir
      File.join(config_home, "souji", "scenario")
    end

    def cache_dir
      File.join(cache_home, "souji")
    end

    def log_dir
      File.join(state_home, "souji", "log")
    end

    # Resolve the <scenario> argument of `souji plan` to an absolute
    # filesystem path. Raises Souji::ScenarioNotFoundError if the resolved
    # path does not exist on disk.
    def resolve_scenario(arg)
      path = path_shaped?(arg) ? File.expand_path(arg) : File.join(scenario_dir, "#{arg}#{SCENARIO_EXT}")
      raise ScenarioNotFoundError, "scenario file not found: #{path}" unless File.file?(path)

      path
    end

    # Resolve the <plan-file> argument of `souji apply` to an absolute
    # filesystem path. Raises Souji::PlanNotFoundError if the resolved
    # path does not exist on disk.
    def resolve_plan(arg)
      path = path_shaped?(arg) ? File.expand_path(arg) : File.join(cache_dir, "#{arg}#{PLAN_EXT}")
      raise PlanNotFoundError, "plan file not found: #{path}" unless File.file?(path)

      path
    end

    # Compute the default `-o` value for `souji plan <scenario>` when the
    # user did not pass `-o`. Always lands under cache_dir; the basename is
    # derived from the scenario argument (FR-007b).
    def default_plan_output_for(scenario_arg)
      basename =
        if path_shaped?(scenario_arg)
          File.basename(scenario_arg, SCENARIO_EXT)
        else
          scenario_arg
        end
      File.join(cache_dir, "#{basename}#{PLAN_EXT}")
    end

    # Compute the default action-log file destination for a given plan
    # file path. Format: <log_dir>/<UTC-timestamp>-<plan-basename>.jsonl
    # (colons replaced with dashes for filesystem safety; UTC for
    # lexicographic chronological order).
    def default_log_file_for(plan_path:, now: Time.now.utc)
      ts = now.utc.strftime("%Y-%m-%dT%H-%M-%SZ")
      basename = File.basename(plan_path, PLAN_EXT)
      File.join(log_dir, "#{ts}-#{basename}.jsonl")
    end

    def ensure_cache_dir!
      FileUtils.mkdir_p(cache_dir)
    end

    def ensure_log_dir!
      FileUtils.mkdir_p(log_dir)
    end

    # NOTE: there is intentionally no `ensure_scenario_dir!` — the
    # scenario directory is the user's to provision.
  end
end
