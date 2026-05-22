# frozen_string_literal: true

require_relative "recipe"

module Souji
  # Namespace for built-in recipe classes. The recipes self-register into
  # Souji::Recipe.registry via the `recipe_name` declaration in their class
  # bodies; this module's only job is to make sure those class bodies have
  # been evaluated by the time someone asks for the registry.
  #
  # See contracts/recipe-interface.md for the contract each recipe must
  # implement.
  module Recipes
    autoload :GitWorktree,        "souji/recipes/git_worktree"
    autoload :TerraformProvider,  "souji/recipes/terraform_provider"
    autoload :DockerImage,        "souji/recipes/docker_image"

    BUILTIN_NAMES = %w[git-worktree terraform-provider docker-image].freeze

    module_function

    # Force-load every built-in recipe so Souji::Recipe.registry is
    # populated. Idempotent — handles the case where someone called
    # Souji::Recipe.reset_registry! between invocations (tests do this).
    def load_builtins!
      BUILTIN_NAMES.each do |name|
        klass = const_get(class_name_for(name))
        Souji::Recipe.register(name, klass) unless Souji::Recipe.registry.key?(name)
      end
      Souji::Recipe.registry
    end

    def class_name_for(name)
      name.split("-").map(&:capitalize).join
    end
  end
end
