# frozen_string_literal: true

require "stringio"
require "souji/progress"

RSpec.describe Souji::Progress do
  let(:io) { StringIO.new }
  let(:progress) { described_class.new(io: io) }

  describe ".null" do
    it "is disabled and swallows every message" do
      null = described_class.null
      expect(null.enabled?).to be false
      null.scenario_start("/tmp/weekly.rb", ["/tmp/work"])
      null.recipe_start("git-worktree", index: 1, total: 1, targets: ["/tmp/work"])
      null.scanning("/tmp/work/repo")
      null.recipe_finish("git-worktree", 2)
      null.recipe_skipped("docker-image", "docker")
      # Nothing to assert on an IO — the point is that none of the above raises
      # and no writer is ever touched.
      expect(null.io).to be_nil
    end
  end

  describe "#enabled?" do
    it "is true when an IO is present" do
      expect(progress.enabled?).to be true
    end
  end

  describe "#scenario_start" do
    it "reports the scenario path and its target roots" do
      progress.scenario_start("/tmp/weekly.rb", ["/tmp/a", "/tmp/b"])
      expect(io.string).to eq(
        "[souji] scenario /tmp/weekly.rb\n" \
        "[souji] targets: /tmp/a, /tmp/b\n"
      )
    end

    it "omits the targets line when no target root is declared" do
      progress.scenario_start("/tmp/weekly.rb", [])
      expect(io.string).to eq("[souji] scenario /tmp/weekly.rb\n")
    end
  end

  describe "#recipe_start" do
    it "reports position, recipe name and the invocation targets" do
      progress.recipe_start("git-worktree", index: 2, total: 3, targets: ["/tmp/a"])
      expect(io.string).to eq("[souji] [2/3] recipe git-worktree (targets: /tmp/a)\n")
    end

    it "omits the targets clause for target-less recipes" do
      progress.recipe_start("docker-image", index: 1, total: 1, targets: [])
      expect(io.string).to eq("[souji] [1/1] recipe docker-image\n")
    end
  end

  describe "#scanning" do
    it "indents the currently scanned target under its recipe" do
      progress.scanning("/tmp/a/repo")
      expect(io.string).to eq("[souji]   scanning /tmp/a/repo\n")
    end
  end

  describe "#recipe_finish" do
    it "pluralizes the item count" do
      progress.recipe_finish("git-worktree", 1)
      progress.recipe_finish("git-worktree", 0)
      progress.recipe_finish("git-worktree", 2)
      expect(io.string).to eq(
        "[souji] recipe git-worktree: 1 item\n" \
        "[souji] recipe git-worktree: 0 items\n" \
        "[souji] recipe git-worktree: 2 items\n"
      )
    end
  end

  describe "#recipe_skipped" do
    it "names the recipe and the missing command" do
      progress.recipe_skipped("docker-image", "docker")
      expect(io.string).to eq("[souji] recipe \"docker-image\" skipped: command \"docker\" not found\n")
    end
  end
end
