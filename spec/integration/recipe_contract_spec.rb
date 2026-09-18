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

  # A recipe whose items sit outside the target roots must say so, because
  # `souji recipes` and the apply confirmation are built from the
  # declaration. Souji::Scenario raises when a recipe emits a synthetic
  # URI without it; this records which recipes take the exception today,
  # so adding one is a deliberate edit rather than a side effect.
  it "keeps the set of scope-free recipes small and deliberate" do
    expect(recipes.select(&:scope_free?).map(&:recipe_name).sort)
      .to eq(%w[brew-cache docker-build-cache docker-container docker-image go-cache
                mise-version pnpm-store uv-cache])
  end
end
