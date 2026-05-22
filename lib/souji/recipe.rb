# frozen_string_literal: true

require "shellwords"
require_relative "errors"

module Souji
  # Abstract base class for every cleanup recipe.
  #
  # Concrete recipes inherit from this class and declare:
  # - `recipe_name "<name>"` (required) — stable identifier used in the DSL
  #   and in plan files.
  # - `required_external_commands "<cmd>", ...` (optional) — executables the
  #   recipe shells out to; probed at plan time per FR-020.
  # - `description "..."` (optional) — used by `souji help recipes`.
  #
  # And implement:
  # - `#enumerate(target_roots, params) -> Array<PlanItem>`
  # - `#verify(plan_item) -> :ok | [:skip, reason]`
  # - `#delete(plan_item) -> :deleted | :trashed | [:failed, error]`
  #
  # See specs/001-souji-cli-recipe-plan/contracts/recipe-interface.md.
  class Recipe
    NAME_FORMAT = /\A[a-z][a-z0-9-]*\z/

    class << self
      def recipe_name(name = nil)
        return @recipe_name if name.nil?

        unless name.is_a?(String) && NAME_FORMAT.match?(name)
          raise ArgumentError, "recipe_name must match #{NAME_FORMAT.source}: got #{name.inspect}"
        end

        @recipe_name = name
        Recipe.register(name, self)
      end

      def required_external_commands(*cmds)
        if cmds.empty?
          @required_external_commands ||= []
        else
          @required_external_commands = cmds.flatten.map(&:to_s)
        end
      end

      def description(text = nil)
        return @description if text.nil?

        @description = text
      end

      def registry
        @registry ||= {}
      end

      def register(name, klass)
        if registry.key?(name) && registry[name] != klass
          raise DuplicateRecipeError, "recipe_name #{name.inspect} already registered to #{registry[name]}"
        end

        registry[name] = klass
      end

      def fetch(name)
        registry.fetch(name) do
          raise UnknownRecipeError,
                "unknown recipe #{name.inspect}; known recipes: #{registry.keys.sort.join(", ")}"
        end
      end

      def reset_registry!
        @registry = {}
      end

      def available?(cmd)
        return false unless cmd.is_a?(String) && !cmd.empty?

        system("command -v #{Shellwords.escape(cmd)} >/dev/null 2>&1")
      end
    end

    def enumerate(_target_roots, _params)
      raise NotImplementedError, "#{self.class}#enumerate must be implemented"
    end

    def verify(_plan_item)
      raise NotImplementedError, "#{self.class}#verify must be implemented"
    end

    def delete(_plan_item)
      raise NotImplementedError, "#{self.class}#delete must be implemented"
    end
  end
end
