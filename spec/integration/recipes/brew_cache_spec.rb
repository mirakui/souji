# frozen_string_literal: true

require "souji/recipes/brew_cache"

# Real `brew cleanup --dry-run`, which is non-mutating. #delete is never
# called here.
RSpec.describe Souji::Recipes::BrewCache, :brew do
  let(:recipe) { described_class.new }

  before { requires_tool!("brew") }

  it "reads a real total and a real path list from the dry run" do
    items = recipe.enumerate([], {})
    skip "nothing to clean on this machine" if items.empty?

    item = items.first
    expect(item.metadata["argv"]).to eq(%w[brew cleanup --prune=all])
    expect(item.metadata["would_remove_count"]).to be > 0
    expect(item.metadata["would_remove"]).to all(start_with("/"))
    expect(item.size_bytes).to be_a(Integer).and(be > 0)
    expect(recipe.verify(item)).to eq(:ok)
  end
end
