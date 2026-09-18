# frozen_string_literal: true

require "souji/recipes/mise_version"

# Real `mise ls --prunable --json` only. #delete is never called here: it
# would uninstall the developer's actual tool versions.
RSpec.describe Souji::Recipes::MiseVersion, :mise do
  let(:recipe) { described_class.new }

  before { requires_tool!("mise") }

  it "reads real prunable versions and measures their install directories" do
    items = recipe.enumerate([], {})
    skip "nothing prunable on this machine" if items.empty?

    items.each do |item|
      expect(item.path).to start_with("mise-version://")
      expect(Dir.exist?(item.metadata["install_path"])).to be true
      expect(item.size_bytes).to be_a(Integer)
      expect(item.metadata["argv"].first(2)).to eq(%w[mise uninstall])
    end
    expect(recipe.verify(items.first)).to eq(:ok)
  end

  it "narrows to a named tool without re-querying differently" do
    tool = recipe.enumerate([], {}).first&.metadata&.fetch("tool")
    skip "nothing prunable on this machine" unless tool

    expect(recipe.enumerate([], tools: [tool]).map { |i| i.metadata["tool"] }.uniq).to eq([tool])
  end
end
