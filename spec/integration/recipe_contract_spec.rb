# frozen_string_literal: true

require "souji/recipes"

# Shared expectations applied to every registered recipe: deterministic
# enumeration, verify :ok for freshly-enumerated items, scope refusal.
RSpec.describe "Recipe contract (shared expectations)" do
  before(:all) do
    Souji::Recipes.load_builtins!
  end

  let(:recipes) do
    Souji::Recipes::BUILTIN_NAMES.map { |name| Souji::Recipe.fetch(name) }
  end

  it "every registered recipe declares a non-empty recipe_name" do
    recipes.each do |klass|
      expect(klass.recipe_name).to be_a(String)
      expect(klass.recipe_name).not_to be_empty
    end
  end

  it "every recipe responds to enumerate / verify / delete" do
    recipes.each do |klass|
      instance = klass.new
      expect(instance).to respond_to(:enumerate)
      expect(instance).to respond_to(:verify)
      expect(instance).to respond_to(:delete)
    end
  end

  it "every recipe declares its required external commands as strings" do
    recipes.each do |klass|
      expect(klass.required_external_commands).to all be_a(String)
    end
  end

  it "every recipe has a description for `souji help recipes`" do
    recipes.each do |klass|
      expect(klass.description).to be_a(String).and(satisfy { |s| !s.empty? })
    end
  end

  # souji's headline safety promise is that nothing outside a declared
  # target is touched, and a synthetic-URI path is the one way out of it.
  # Checking the declaration against the paths a recipe actually emits, in
  # both directions, turns the escape hatch from an unenforced convention
  # into something a reviewer can rely on.
  describe "scope containment and its declared exception" do
    it "declares scope_free! exactly when a recipe's items escape the target roots" do
      by_declaration = recipes.group_by(&:scope_free?)

      expect(by_declaration[true].map(&:recipe_name).sort).to eq(escaping_recipe_names.sort)
      expect(by_declaration[false].map(&:recipe_name) & escaping_recipe_names).to be_empty
    end

    # A recipe escapes containment when the paths it builds are synthetic
    # URIs. Read off the source rather than guessed: every plan item a
    # scope-free recipe builds does so from a "<scheme>://" literal named
    # after the recipe.
    def escaping_recipe_names
      recipes.map(&:recipe_name).select do |name|
        source = File.read(recipe_source_path(name))
        source.include?(%("#{name}://))
      end
    end

    def recipe_source_path(name)
      File.expand_path("../../lib/souji/recipes/#{name.tr("-", "_")}.rb", __dir__)
    end
  end
end
