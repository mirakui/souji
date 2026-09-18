# frozen_string_literal: true

require "souji/recipes/uv_cache"

RSpec.describe Souji::Recipes::UvCache do
  let(:recipe) { described_class.new }

  def stub_uv(dir: "/tmp/uvcache", size: uv_cache_size, size_exit: 0)
    FileUtils.mkdir_p(dir)
    stub_external("uv", "cache", "dir", stdout: "#{dir}\n")
    stub_external("uv", "cache", "size", stdout: size, stderr: uv_cache_size_stderr,
                                         exitstatus: size_exit)
    dir
  end

  describe "class-level declarations" do
    it "registers under 'uv-cache' and requires uv" do
      expect(described_class.recipe_name).to eq("uv-cache")
      expect(described_class.required_external_commands).to eq(["uv"])
    end

    it "declares itself scope-free, because uv's cache is not under any target root" do
      expect(described_class.scope_free?).to be true
    end

    it "takes no params: uv decides what is unreachable, not the scenario" do
      expect(described_class.param_names).to eq([])
    end
  end

  describe "#enumerate" do
    it "proposes one opaque item carrying the literal command apply will run" do
      dir = stub_uv

      items = recipe.enumerate([], {})

      expect(items.size).to eq(1)
      expect(items.first.path).to eq("uv-cache://prune")
      expect(items.first.path).to match(Souji::Plan::SYNTHETIC_URI_RE)
      expect(items.first.metadata).to include(
        "argv" => %w[uv cache prune], "delegated_to" => "uv cache prune",
        "command" => "uv", "cache_dir" => dir,
        "irreversible" => true, "scope_free" => true
      )
    end

    it "reports no size, only an upper bound, because uv cannot say what is reclaimable" do
      # `uv cache size` is the size of the whole cache; prune removes only
      # unreachable objects. Summing that into the plan's total would turn
      # "at least this much" into a promise souji cannot keep.
      stub_uv

      item = recipe.enumerate([], {}).first

      expect(item.size_bytes).to be_nil
      expect(item.metadata["size_bytes_upper_bound"]).to eq(10_007_912_448)
      expect(item.metadata["size_basis"]).to match(/whole cache/)
    end

    it "omits the upper bound rather than guessing when uv cannot report a size" do
      stub_uv(size: "", size_exit: 2)

      expect(recipe.enumerate([], {}).first.metadata).not_to have_key("size_bytes_upper_bound")
    end

    it "proposes nothing when uv has no cache directory yet" do
      stub_external("uv", "cache", "dir", stdout: "/tmp/souji-no-such-uv-cache\n")

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "proposes nothing when uv cannot report its cache directory" do
      stub_external("uv", "cache", "dir", stdout: "", exitstatus: 1)

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "never runs a mutating command while planning" do
      stub_uv

      recipe.enumerate([], {})

      expect_only_read_only_calls!
    end
  end

  describe "#verify" do
    let(:item) { stub_uv.then { recipe.enumerate([], {}).first } }

    it "accepts an item whose tool and cache directory are both still there" do
      expect(recipe.verify(item)).to eq(:ok)
    end

    it "skips once uv has left PATH" do
      subject_item = item
      allow(Souji::Recipe).to receive(:available?).with("uv").and_return(false)

      expect(recipe.verify(subject_item)).to eq([:skip, "uv is no longer on PATH"])
    end

    it "skips once the cache directory has gone" do
      subject_item = item
      FileUtils.remove_entry(subject_item.metadata["cache_dir"])

      expect(recipe.verify(subject_item).last).to match(/no longer exists/)
    end
  end

  describe "#delete" do
    let(:item) { stub_uv.then { recipe.enumerate([], {}).first } }

    it "runs exactly the recorded argv and reports :deleted, never :trashed" do
      subject_item = item
      stub_external("uv", "cache", "prune", stdout: "Removed 1234 files\n")

      expect(recipe.delete(subject_item)).to eq(:deleted)
      expect(external_calls).to include(%w[uv cache prune])
    end

    it "reports the tool's own last line of stderr on failure" do
      subject_item = item
      stub_external("uv", "cache", "prune", stderr: "error: failed to read cache\n", exitstatus: 2)

      expect(recipe.delete(subject_item)).to match([:failed, /failed to read cache/])
    end

    it "reports a timeout as a failure rather than hanging apply" do
      subject_item = item
      stub_external("uv", "cache", "prune", exitstatus: -1, timed_out: true)

      expect(recipe.delete(subject_item)).to match([:failed, /timed out after 900s/])
    end
  end
end
