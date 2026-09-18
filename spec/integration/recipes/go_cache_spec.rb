# frozen_string_literal: true

require "souji/recipes/go_cache"

# Real `go env` only. #delete is never called here: it would wipe the
# developer's actual build and module caches.
RSpec.describe Souji::Recipes::GoCache, :go do
  let(:recipe) { described_class.new }

  before { requires_tool!("go") }

  it "proposes nothing for a bare invocation, even with a real go present" do
    expect(recipe.enumerate([], {})).to eq([])
  end

  it "measures the real caches when both halves are asked for" do
    items = recipe.enumerate([], build_cache: true, mod_cache: true)
    skip "no go caches on this machine" if items.empty?

    items.each do |item|
      expect(Dir.exist?(item.metadata["cache_dir"])).to be true
      expect(item.size_bytes).to be_a(Integer)
      expect(recipe.verify(item)).to eq(:ok)
    end
  end
end
