# frozen_string_literal: true

require "souji/recipes/docker_image"

RSpec.describe Souji::Recipes::DockerImage, :docker do
  let(:recipe) { described_class.new }

  describe "class-level declarations" do
    it "registers under 'docker-image'" do
      expect(described_class.recipe_name).to eq("docker-image")
    end

    it "requires the docker external command" do
      expect(described_class.required_external_commands).to eq(["docker"])
    end
  end

  describe "#enumerate" do
    it "returns dangling images as plan items with synthetic URIs" do
      requires_docker!
      # Set up: pull a tiny image, tag it, untag → dangling.
      system("docker", "pull", "-q", "hello-world", out: File::NULL, err: File::NULL)
      id = `docker images -q hello-world`.lines.first.to_s.strip
      tag = "souji-spec/dangling:#{Time.now.to_i}"
      system("docker", "tag", id, tag, out: File::NULL, err: File::NULL)
      system("docker", "rmi", tag, out: File::NULL, err: File::NULL)
      begin
        items = recipe.enumerate([], {})
        expect(items).to all be_a(Souji::PlanItem)
        items.each do |item|
          expect(item.recipe).to eq("docker-image")
          expect(item.path).to start_with("docker-image://sha256:")
          expect(item.metadata["irreversible"]).to be true
        end
      ensure
        # best-effort cleanup; do not fail spec on cleanup error.
        system("docker", "image", "prune", "-f", out: File::NULL, err: File::NULL)
      end
    end
  end
end
