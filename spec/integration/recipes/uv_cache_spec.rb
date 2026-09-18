# frozen_string_literal: true

require "souji/recipes/uv_cache"

# Runs the real `uv` probes. Structure and read-only-ness only: #delete is
# never called here, because it would prune the developer's actual cache.
RSpec.describe Souji::Recipes::UvCache, :uv do
  let(:recipe) { described_class.new }

  before { requires_tool!("uv") }

  it "finds the real cache directory and offers an upper bound for it" do
    items = recipe.enumerate([], {})

    expect(items.size).to eq(1)
    item = items.first
    expect(item.path).to eq("uv-cache://prune")
    expect(Dir.exist?(item.metadata["cache_dir"])).to be true
    expect(item.size_bytes).to be_nil
    expect(item.metadata["size_bytes_upper_bound"]).to be_a(Integer).and(be > 0)
  end

  it "verifies against the live tool" do
    expect(recipe.verify(recipe.enumerate([], {}).first)).to eq(:ok)
  end
end
