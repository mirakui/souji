# frozen_string_literal: true

require "souji/recipes/docker_container"

# Real docker probes. #delete is never called here: it would remove the
# developer's actual containers.
RSpec.describe Souji::Recipes::DockerContainer, :docker do
  let(:recipe) { described_class.new }

  before do
    requires_docker!
    Souji::External::Docker.reset!
  end

  after { Souji::External::Docker.reset! }

  it "proposes only containers docker itself reports as terminal" do
    items = recipe.enumerate([], {})
    skip "no stopped containers on this machine" if items.empty?

    running = `docker ps -q --no-trunc`.lines.map(&:strip)
    expect(items.map { |i| i.metadata["container_id"] } & running).to be_empty
    items.each do |item|
      expect(described_class::TERMINAL_STATES).to include(item.metadata["state"])
      expect(recipe.verify(item)).to eq(:ok)
    end
  end
end
