# frozen_string_literal: true

require "thor"
require_relative "version"
require_relative "commands"
require_relative "recipe"
require_relative "recipes"

module Souji
  # Top-level CLI dispatcher. Each subcommand resolves to a
  # Souji::Commands::* class that does the actual work.
  class CLI < Thor
    class_option :verbose, type: :boolean, aliases: "-v", default: false,
                           desc: "Verbose output (currently unused)"

    def self.exit_on_failure?
      true
    end

    desc "init", "Generate the default scenario template"
    long_desc <<~LONG
      Create $XDG_CONFIG_HOME/souji/scenario/default.rb — the scenario
      `souji plan` reads when no argument is given. The generated template is
      entirely commented out, so it proposes nothing until you edit it.
      An existing default.rb is left untouched unless --force is passed.
    LONG
    method_option :force, type: :boolean, default: false,
                          desc: "Overwrite an existing default.rb"
    def init
      exit_code = Commands::InitCommand.new.call(force: options[:force])
      exit(exit_code) unless exit_code.zero?
    end

    desc "plan [SCENARIO]", "Generate a YAML plan from a scenario"
    long_desc <<~LONG
      Resolve SCENARIO (bare name → $XDG_CONFIG_HOME/souji/scenario/<name>.rb,
      otherwise treated as a filesystem path), run each declared recipe in
      read-only mode, and write a YAML plan to -o (default
      $XDG_CACHE_HOME/souji/<name>.soujiplan).

      SCENARIO defaults to "default", i.e. bare `souji plan` is the same as
      `souji plan default`. Run `souji init` to generate that scenario.
    LONG
    method_option :output, type: :string, aliases: "-o",
                           desc: "Plan output path (bare name or filesystem path)"
    method_option :target_root, type: :array, default: [],
                                desc: "Extra target roots merged with scenario-declared targets"
    method_option :quiet, type: :boolean, default: false,
                          desc: "Suppress per-recipe progress on stderr"
    def plan(scenario = nil)
      exit_code = Commands::PlanCommand.new.call(
        scenario,
        output: options[:output],
        target_roots: options[:target_root],
        quiet: options[:quiet]
      )
      exit(exit_code) unless exit_code.zero?
    end

    desc "apply [PLAN]", "Apply a previously generated plan"
    long_desc <<~LONG
      Resolve PLAN (bare name → $XDG_CACHE_HOME/souji/<name>.soujiplan,
      otherwise treated as a filesystem path), prompt for confirmation,
      then run each plan item through Recipe#verify + Recipe#delete.
      Logs to stderr and (by default) to $XDG_STATE_HOME/souji/log/.

      PLAN defaults to "default", matching bare `souji plan`.
    LONG
    method_option :yes, type: :boolean, default: false,
                        desc: "Proceed without the interactive y/N prompt"
    method_option :dry_run, type: :boolean, default: false,
                            desc: "Report what would be deleted without deleting"
    method_option :log_file, type: :string,
                             desc: "Override the action log destination"
    method_option :no_log_file, type: :boolean, default: false,
                                desc: "Suppress action log file (stderr only)"
    def apply(plan = nil)
      exit_code = Commands::ApplyCommand.new.call(
        plan,
        yes: options[:yes],
        dry_run: options[:dry_run],
        log_file: options[:log_file],
        no_log_file: options[:no_log_file]
      )
      exit(exit_code) unless exit_code.zero?
    end

    desc "version", "Print the souji version and exit"
    def version
      $stdout.puts "souji #{Souji::VERSION}"
    end

    map "--version" => :version

    desc "recipes", "List registered recipes with their descriptions and options"
    def recipes
      Souji::Recipes.load_builtins!
      registry = Souji::Recipe.registry.sort.to_h
      width = registry.keys.map(&:length).max || 0
      registry.each do |name, klass|
        desc = klass.description || ""
        $stdout.puts(format("%-#{width}s  %s", name, desc))
        klass.params.each { |param, param_desc| $stdout.puts("#{" " * (width + 2)}  #{param}: #{param_desc}") }
      end
    end
  end
end
