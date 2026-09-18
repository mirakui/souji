# frozen_string_literal: true

require "souji/recipes/pnpm_store"

# Real `pnpm` probes only. #delete is never called here: it would prune the
# developer's actual store.
RSpec.describe Souji::Recipes::PnpmStore, :pnpm do
  let(:recipe) { described_class.new }

  before { requires_tool!("pnpm") }

  it "finds the real store and reports no size for it" do
    item = recipe.enumerate([], {}).first

    expect(item.path).to eq("pnpm-store://prune")
    expect(Dir.exist?(item.metadata["cache_dir"])).to be true
    expect(item.size_bytes).to be_nil
    expect(recipe.verify(item)).to eq(:ok)
  end
end
