# frozen_string_literal: true

require "souji/recipes/go_cache"

RSpec.describe Souji::Recipes::GoCache do
  let(:recipe) { described_class.new }

  def stub_go(build: "/tmp/souji-gocache", mod: "/tmp/souji-gomodcache")
    [build, mod].compact.each { |dir| FileUtils.mkdir_p(dir) }
    File.write(File.join(build, "blob"), "x" * 100) if build
    File.write(File.join(mod, "blob"), "x" * 250) if mod
    stub_external("go", "env", stdout: "#{build}\n#{mod}\n")
    [build, mod]
  end

  describe "class-level declarations" do
    it "registers under 'go-cache', requires go, and is scope-free" do
      expect(described_class.recipe_name).to eq("go-cache")
      expect(described_class.required_external_commands).to eq(["go"])
      expect(described_class.scope_free?).to be true
    end

    it "declares both halves as separate opt-ins" do
      expect(described_class.param_names).to eq(%i[build_cache mod_cache])
    end
  end

  describe "#enumerate" do
    it "proposes nothing at all when neither half was asked for" do
      # go clean removes everything, not just what is unreferenced, so a
      # bare `recipe "go-cache"` must not be able to wipe anything.
      stub_go

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "says on stderr why a bare invocation proposed nothing" do
      stub_go
      progress = instance_double(Souji::Progress)
      recipe.progress = progress

      expect(progress).to receive(:note).with(/unless build_cache: or mod_cache: is set/)

      recipe.enumerate([], {})
    end

    it "proposes only the half that was asked for" do
      stub_go

      expect(recipe.enumerate([], build_cache: true).map(&:path)).to eq(["go-cache://build-cache"])
      expect(recipe.enumerate([], mod_cache: true).map(&:path)).to eq(["go-cache://mod-cache"])
    end

    it "proposes the two halves as separate items, because their costs differ" do
      stub_go

      items = recipe.enumerate([], build_cache: true, mod_cache: true)

      expect(items.map(&:path)).to eq(["go-cache://build-cache", "go-cache://mod-cache"])
      expect(items.map { |i| i.metadata["argv"] })
        .to eq([%w[go clean -cache], %w[go clean -modcache]])
      expect(items.last.reason).to match(/needs the network/)
    end

    it "reports a real size, not an upper bound, because the whole directory goes" do
      stub_go

      items = recipe.enumerate([], build_cache: true, mod_cache: true)

      expect(items.map(&:size_bytes)).to eq([100, 250])
      expect(items.first.metadata).not_to have_key("size_bytes_upper_bound")
      expect(items.first.metadata["size_basis"]).to match(/removes it entirely|entirely/)
    end

    it "skips a half whose directory does not exist" do
      stub_external("go", "env", stdout: "/tmp/souji-no-such-gocache\n/tmp/souji-no-such-gomod\n")

      expect(recipe.enumerate([], build_cache: true, mod_cache: true)).to eq([])
    end

    it "proposes nothing when go cannot report its cache directories" do
      stub_external("go", "env", stdout: "", exitstatus: 1)

      expect(recipe.enumerate([], build_cache: true)).to eq([])
    end

    it "never runs a mutating command while planning" do
      stub_go

      recipe.enumerate([], build_cache: true, mod_cache: true)

      expect_only_read_only_calls!
    end
  end

  describe "#verify" do
    it "accepts an item whose cache directory is still there" do
      stub_go

      expect(recipe.verify(recipe.enumerate([], build_cache: true).first)).to eq(:ok)
    end

    it "skips once the cache directory has gone" do
      build, = stub_go
      item = recipe.enumerate([], build_cache: true).first
      FileUtils.remove_entry(build)

      expect(recipe.verify(item).last).to match(/no longer exists/)
    end
  end

  describe "#delete" do
    it "runs exactly the recorded argv for the half it belongs to" do
      stub_go
      item = recipe.enumerate([], mod_cache: true).first
      stub_external("go", "clean", "-modcache", stdout: "")

      expect(recipe.delete(item)).to eq(:deleted)
      expect(external_calls).to include(%w[go clean -modcache])
      expect(external_calls).not_to include(%w[go clean -cache])
    end

    it "reports a timeout as a failure, since a modcache wipe can run for minutes" do
      stub_go
      item = recipe.enumerate([], mod_cache: true).first
      stub_external("go", "clean", "-modcache", exitstatus: -1, timed_out: true)

      expect(recipe.delete(item)).to match([:failed, /timed out after 900s/])
    end
  end
end
