# frozen_string_literal: true

require "souji/recipes/pnpm_store"

RSpec.describe Souji::Recipes::PnpmStore do
  let(:recipe) { described_class.new }

  def stub_pnpm(dir: "/tmp/pnpm-store-v10")
    FileUtils.mkdir_p(dir)
    stub_external("pnpm", "store", "path", stdout: "#{dir}\n")
    dir
  end

  describe "class-level declarations" do
    it "registers under 'pnpm-store', requires pnpm, and is scope-free" do
      expect(described_class.recipe_name).to eq("pnpm-store")
      expect(described_class.required_external_commands).to eq(["pnpm"])
      expect(described_class.scope_free?).to be true
      expect(described_class.param_names).to eq([])
    end
  end

  describe "#enumerate" do
    it "proposes one opaque item carrying the literal command apply will run" do
      dir = stub_pnpm

      item = recipe.enumerate([], {}).first

      expect(item.path).to eq("pnpm-store://prune")
      expect(item.metadata).to include("argv" => %w[pnpm store prune], "cache_dir" => dir,
                                       "irreversible" => true)
    end

    it "reports no size at all, and says why" do
      # The store is hardlinked into the node_modules trees the
      # node-modules recipe already measures, so walking it would double
      # count; and pnpm reports neither a total nor a reclaimable figure.
      stub_pnpm

      item = recipe.enumerate([], {}).first

      expect(item.size_bytes).to be_nil
      expect(item.metadata).not_to have_key("size_bytes_upper_bound")
      expect(item.metadata["size_basis"]).to match(/hardlinked into/)
    end

    it "never consults pnpm store status, which answers a different question" do
      stub_pnpm

      recipe.enumerate([], {})

      expect(external_calls).not_to include(%w[pnpm store status])
    end

    it "proposes nothing when pnpm has no store yet" do
      stub_external("pnpm", "store", "path", stdout: "/tmp/souji-no-such-pnpm-store\n")

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "proposes nothing when pnpm cannot report its store path" do
      stub_external("pnpm", "store", "path", stdout: "", exitstatus: 1)

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "never runs a mutating command while planning" do
      stub_pnpm

      recipe.enumerate([], {})

      expect_only_read_only_calls!
    end
  end

  describe "#verify" do
    it "accepts an item whose tool and store are both still there" do
      stub_pnpm

      expect(recipe.verify(recipe.enumerate([], {}).first)).to eq(:ok)
    end

    it "skips once the store has gone" do
      dir = stub_pnpm
      item = recipe.enumerate([], {}).first
      FileUtils.remove_entry(dir)

      expect(recipe.verify(item).last).to match(/no longer exists/)
    end
  end

  describe "#delete" do
    it "runs the recorded argv and reports :deleted" do
      stub_pnpm
      item = recipe.enumerate([], {}).first
      stub_external("pnpm", "store", "prune", stdout: "Removed 100 files\n")

      expect(recipe.delete(item)).to eq(:deleted)
      expect(external_calls).to include(%w[pnpm store prune])
    end

    it "reports a failure with the tool's own message" do
      stub_pnpm
      item = recipe.enumerate([], {}).first
      stub_external("pnpm", "store", "prune", stderr: "ERR_PNPM_STORE_BREAKING\n", exitstatus: 1)

      expect(recipe.delete(item)).to match([:failed, /ERR_PNPM_STORE_BREAKING/])
    end
  end
end
