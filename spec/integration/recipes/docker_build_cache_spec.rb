# frozen_string_literal: true

require "souji/recipes/docker_build_cache"

# Real `docker system df`. #delete is never called here: it would prune the
# developer's actual build cache.
RSpec.describe Souji::Recipes::DockerBuildCache, :docker do
  let(:recipe) { described_class.new }

  before do
    requires_docker!
    Souji::External::Docker.reset!
  end

  after { Souji::External::Docker.reset! }

  it "reads a real reclaimable figure and never asks for -a" do
    items = recipe.enumerate([], {})
    skip "no reclaimable build cache on this machine" if items.empty?

    item = items.first
    expect(item.size_bytes).to be_a(Integer).and(be > 0)
    expect(item.metadata["argv"]).not_to include("-a")
    expect(recipe.verify(item)).to eq(:ok)
  end
end
