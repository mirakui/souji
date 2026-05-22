# frozen_string_literal: true

module Souji
  # Base class for every error raised intentionally by Souji.
  class Error < StandardError; end

  # Raised when a plan file's `souji_plan_version` is not a version this
  # build of Souji can read.
  class IncompatiblePlanError < Error; end

  # Raised when a PlanItem's path is not under any of the plan's declared
  # target_roots, or a recipe attempts to enumerate / operate on a path
  # outside the invoking scenario's declared scope (FR-016 / FR-019).
  class ScopeViolationError < Error; end

  # Raised when a scenario references a recipe that is not in the registry
  # (FR-004 / FR-007a usage error path).
  class UnknownRecipeError < Error; end

  # Raised when two Recipe subclasses declare the same `recipe_name`.
  class DuplicateRecipeError < Error; end

  # Raised when a scenario file does not exist at the resolved path.
  class ScenarioNotFoundError < Error; end

  # Raised when a plan file does not exist at the resolved path.
  class PlanNotFoundError < Error; end

  # Raised when scenario-time DSL violates scope (e.g., per-recipe targets:
  # escapes scenario-level target set).
  class ScenarioError < Error; end
end
