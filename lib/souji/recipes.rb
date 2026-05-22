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
    # populated. Idempotent.
    def load_builtins!
      _ = GitWorktree
      _ = TerraformProvider
      _ = DockerImage
      Souji::Recipe.registry
    end
  end
end
