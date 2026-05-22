# frozen_string_literal: true

require_relative "souji/version"
require_relative "souji/errors"

module Souji
  # Top-level namespace. Submodules (Paths, PlanItem, Plan, Recipe, Recipes,
  # DSL, Scenario, Commands, ActionLog, Trash, Confirmation, CLI) are
  # autoloaded on first reference; tests can also `require "souji/<name>"`
  # explicitly when they need a specific module without pulling the rest.
  autoload :Paths,        "souji/paths"
  autoload :PlanItem,     "souji/plan_item"
  autoload :Plan,         "souji/plan"
  autoload :Recipe,       "souji/recipe"
  autoload :Recipes,      "souji/recipes"
  autoload :DSL,          "souji/dsl"
  autoload :Scenario,     "souji/scenario"
  autoload :ActionLog,    "souji/action_log"
  autoload :Trash,        "souji/trash"
  autoload :Confirmation, "souji/confirmation"
  autoload :Commands,     "souji/commands"
  autoload :CLI,          "souji/cli"
end
