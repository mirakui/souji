# frozen_string_literal: true

require "souji/plan"
require "fileutils"
require "tmpdir"

RSpec.describe Souji::Plan do
  let(:example_plan_path) do
    File.expand_path(
      "../../specs/001-souji-cli-recipe-plan/contracts/examples/plan-example.yaml",
      __dir__
    )
  end

  let(:empty_plan_path) do
    File.expand_path(
      "../../specs/001-souji-cli-recipe-plan/contracts/examples/plan-empty-example.yaml",
      __dir__
    )
  end

  describe ".load_yaml" do
    it "loads the fully populated example plan" do
      plan = described_class.load_yaml(example_plan_path)
      expect(plan.souji_plan_version).to eq(1)
      expect(plan.souji_version).to eq("0.1.0")
      expect(plan.target_roots).to include(
        "/Users/naruta/work",
        "/Users/naruta/playground"
      )
      expect(plan.items.size).to eq(8)
    end

    it "loads the empty example plan" do
      plan = described_class.load_yaml(empty_plan_path)
      expect(plan.items).to eq([])
      expect(plan.target_roots).to eq(["/Users/naruta/work"])
    end

    it "reifies each item as a Souji::PlanItem" do
      plan = described_class.load_yaml(example_plan_path)
      plan.items.each { |i| expect(i).to be_a(Souji::PlanItem) }
    end

    it "raises Souji::IncompatiblePlanError on unknown souji_plan_version" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "bad.soujiplan")
        File.write(path, <<~YAML)
          souji_plan_version: 999
          souji_version: "0.1.0"
          generated_at: "2026-05-22T13:45:01+09:00"
          scenario: { path: "x", content_sha256: "abc" }
          target_roots: ["/tmp"]
          items: []
        YAML
        expect { described_class.load_yaml(path) }
          .to raise_error(Souji::IncompatiblePlanError, /version/)
      end
    end

    it "raises Souji::ScopeViolationError when an item path is outside target_roots" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "bad.soujiplan")
        File.write(path, <<~YAML)
          souji_plan_version: 1
          souji_version: "0.1.0"
          generated_at: "2026-05-22T13:45:01+09:00"
          scenario: { path: "x", content_sha256: "abc" }
          target_roots: ["/Users/naruta/work"]
          items:
            - id: "git-worktree:01HZQK2H4Z9YPC7A0F0F4F0F4F"
              recipe: "git-worktree"
              path: "/etc/passwd"
              reason: "scope-escape attempt"
        YAML
        expect { described_class.load_yaml(path) }
          .to raise_error(Souji::ScopeViolationError, %r{/etc/passwd})
      end
    end

    it "exempts synthetic-URI items (docker-image://) from scope containment" do
      plan = described_class.load_yaml(example_plan_path)
      docker_items = plan.items.select { |i| i.path.start_with?("docker-image://") }
      expect(docker_items.size).to be >= 1
    end
  end

  describe "#dump_yaml round-trip" do
    it "writes a plan that load_yaml reads back as an equivalent Plan" do
      original = described_class.load_yaml(example_plan_path)
      Dir.mktmpdir do |dir|
        out = File.join(dir, "round.soujiplan")
        original.dump_yaml(out)
        reloaded = described_class.load_yaml(out)
        expect(reloaded.target_roots).to eq(original.target_roots)
        expect(reloaded.items).to eq(original.items)
        expect(reloaded.souji_plan_version).to eq(1)
      end
    end
  end

  describe "#summary" do
    it "returns per-recipe item counts and total size" do
      plan = described_class.load_yaml(example_plan_path)
      summary = plan.summary
      expect(summary[:by_recipe]).to include(
        "git-worktree" => hash_including(count: 3),
        "terraform-provider" => hash_including(count: 3),
        "docker-image" => hash_including(count: 2)
      )
      expect(summary[:total_count]).to eq(8)
      expect(summary[:total_bytes]).to be > 0
    end

    it "returns zero counts for an empty plan" do
      plan = described_class.load_yaml(empty_plan_path)
      summary = plan.summary
      expect(summary[:total_count]).to eq(0)
      expect(summary[:total_bytes]).to eq(0)
      expect(summary[:unsized_count]).to eq(0)
      expect(summary[:upper_bound_bytes]).to eq(0)
      expect(summary[:vm_bytes]).to eq(0)
    end

    # size_bytes means "souji believes this much will actually be freed on
    # this host". Two kinds of byte do not meet that bar and must not be
    # summed into the headline the user consents to.
    describe "bytes souji will not promise" do
      def plan_with(*items)
        described_class.new(
          souji_plan_version: 1, souji_version: "0.1.0", generated_at: Time.now.iso8601,
          scenario_path: "/tmp/s.rb", scenario_content_sha256: "x",
          target_roots: ["/tmp"], items: items
        )
      end

      def item(recipe, path, size_bytes: nil, metadata: {})
        Souji::PlanItem.new(id: Souji::PlanItem.generate_id(recipe), recipe: recipe, path: path,
                            reason: "r", size_bytes: size_bytes, metadata: metadata)
      end

      it "keeps an unmeasurable item's whole-cache size out of the total" do
        plan = plan_with(
          item("uv-cache", "uv-cache://prune",
               metadata: { "size_bytes_upper_bound" => 10_000 }),
          item("terraform-dir", "/tmp/a", size_bytes: 500)
        )

        summary = plan.summary

        expect(summary[:total_bytes]).to eq(500)
        expect(summary[:unsized_count]).to eq(1)
        expect(summary[:upper_bound_bytes]).to eq(10_000)
        expect(summary[:by_recipe]["uv-cache"]).to include(unsized: 1, upper_bound: 10_000, bytes: 0)
      end

      it "counts an unmeasurable item with no upper bound without inventing one" do
        plan = plan_with(item("pnpm-store", "pnpm-store://prune"))

        summary = plan.summary

        expect(summary[:unsized_count]).to eq(1)
        expect(summary[:upper_bound_bytes]).to eq(0)
      end

      it "keeps bytes freed inside a VM out of the host total" do
        # Pruning inside a Lima or Docker Desktop VM does not shrink the
        # VM's disk image, so the user's df will not move.
        plan = plan_with(
          item("docker-image", "docker-image://sha256:a", size_bytes: 8_000,
                                                          metadata: { "host_space_unaffected" => true }),
          item("node-modules", "/tmp/n", size_bytes: 200)
        )

        summary = plan.summary

        expect(summary[:total_bytes]).to eq(200)
        expect(summary[:vm_bytes]).to eq(8_000)
        expect(summary[:by_recipe]["docker-image"]).to include(bytes: 0, vm_bytes: 8_000)
      end
    end
  end
end
