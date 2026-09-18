# frozen_string_literal: true

require "souji/recipes/brew_cache"

RSpec.describe Souji::Recipes::BrewCache do
  let(:recipe) { described_class.new }

  def stub_brew(dir: "/tmp/homebrew-cache", dry_run: brew_cleanup_dry_run, prune: "all")
    FileUtils.mkdir_p(dir)
    stub_external("brew", "--cache", stdout: "#{dir}\n")
    stub_external("brew", "cleanup", "--prune=#{prune}", "--dry-run",
                  stdout: dry_run, stderr: brew_cleanup_dry_run_stderr)
    dir
  end

  describe "class-level declarations" do
    it "registers under 'brew-cache', requires brew, and is scope-free" do
      expect(described_class.recipe_name).to eq("brew-cache")
      expect(described_class.required_external_commands).to eq(["brew"])
      expect(described_class.scope_free?).to be true
      expect(described_class.param_names).to eq([:prune_days])
    end
  end

  describe "#enumerate" do
    it "reports a real size from the dry run, read as binary quantities" do
      # Homebrew prints binary sizes behind SI-looking labels: its 667.3MB
      # is 667.3 MiB. Reading it as SI would understate by ~5%.
      stub_brew

      item = recipe.enumerate([], {}).first

      expect(item.size_bytes).to eq(699_714_765)
      expect(item.metadata).not_to have_key("size_bytes_upper_bound")
      expect(item.metadata["size_basis"]).to eq("brew cleanup --prune=all --dry-run total")
    end

    it "proposes a single item, because brew cleanup has no per-file mode" do
      stub_brew

      items = recipe.enumerate([], {})

      expect(items.size).to eq(1)
      expect(items.first.path).to eq("brew-cache://cleanup")
      expect(items.first.metadata["argv"]).to eq(%w[brew cleanup --prune=all])
    end

    it "records the paths it saw so the single item is still reviewable" do
      stub_brew

      metadata = recipe.enumerate([], {}).first.metadata

      expect(metadata["would_remove_count"]).to eq(5)
      expect(metadata["would_remove"].first).to match(%r{Caches/Homebrew/gh_bottle_manifest})
      expect(metadata["would_remove"].size).to be <= 20
    end

    it "parses only stdout, ignoring the Warning noise brew writes to stderr" do
      stub_brew

      expect(recipe.enumerate([], {}).first.metadata["would_remove"]).to all(start_with("/"))
    end

    it "proposes nothing when brew reports nothing to clean" do
      stub_brew(dry_run: brew_cleanup_nothing_to_do)

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "never runs a mutating command while planning" do
      stub_brew

      recipe.enumerate([], {})

      expect_only_read_only_calls!
    end

    describe "with prune_days:" do
      it "carries the same --prune value into the dry run and into the delete command" do
        # A dry run with a different --prune value would report the size of
        # a different operation.
        stub_brew(prune: "30", dry_run: brew_cleanup_dry_run)

        item = recipe.enumerate([], prune_days: 30).first

        expect(item.metadata["argv"]).to eq(%w[brew cleanup --prune=30])
        expect(item.metadata["prune"]).to eq("30")
        expect(external_calls).to include(%w[brew cleanup --prune=30 --dry-run])
        expect(item.reason).to match(/older than 30 days/)
      end
    end
  end

  describe "#verify" do
    it "accepts an item while brew still reports something to clean" do
      stub_brew

      expect(recipe.verify(recipe.enumerate([], {}).first)).to eq(:ok)
    end

    it "skips once brew has nothing left to clean" do
      stub_brew
      item = recipe.enumerate([], {}).first
      stub_external("brew", "cleanup", "--prune=all", "--dry-run", stdout: brew_cleanup_nothing_to_do)

      expect(recipe.verify(item)).to eq([:skip, "brew reports nothing to clean"])
    end

    it "re-runs the dry run with the item's own --prune value" do
      stub_brew(prune: "30")
      item = recipe.enumerate([], prune_days: 30).first

      recipe.verify(item)

      expect(external_calls.count(%w[brew cleanup --prune=30 --dry-run])).to eq(2)
    end
  end

  describe "#delete" do
    it "runs the recorded argv without --dry-run and reports :deleted" do
      stub_brew
      item = recipe.enumerate([], {}).first
      stub_external("brew", "cleanup", "--prune=all", stdout: "Removing...\n")

      expect(recipe.delete(item)).to eq(:deleted)
      expect(external_calls).to include(%w[brew cleanup --prune=all])
    end
  end
end
