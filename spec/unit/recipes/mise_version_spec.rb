# frozen_string_literal: true

require "souji/recipes/mise_version"

RSpec.describe Souji::Recipes::MiseVersion do
  let(:recipe) { described_class.new }

  # The fixture's install paths have to exist for the sizes and the
  # cache-dir re-check to mean anything, so they are rooted in a tmp dir.
  def stub_mise(tmp, json: mise_ls_prunable_json)
    rewritten = json.gsub("/Users/u", tmp)
    JSON.parse(rewritten).each_value do |entries|
      entries.each do |entry|
        next unless entry["installed"]

        FileUtils.mkdir_p(entry["install_path"])
        File.write(File.join(entry["install_path"], "bin"), "x" * 64)
      end
    end
    stub_external("mise", "ls", "--prunable", stdout: rewritten, stderr: mise_ls_prunable_stderr)
    rewritten
  end

  describe "class-level declarations" do
    it "registers under 'mise-version', requires mise, and is scope-free" do
      expect(described_class.recipe_name).to eq("mise-version")
      expect(described_class.required_external_commands).to eq(["mise"])
      expect(described_class.scope_free?).to be true
      expect(described_class.param_names).to eq([:tools])
    end
  end

  describe "#enumerate" do
    it "proposes one item per prunable version, in a stable order" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)

        items = recipe.enumerate([], {})

        expect(items.map(&:path)).to eq([
                                          "mise-version://aqua:open-policy-agent/opa@1.13.2",
                                          "mise-version://awscli@2.30.0",
                                          "mise-version://awscli@2.35.12"
                                        ])
      end
    end

    it "handles a tool name containing a colon and a slash" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)

        item = recipe.enumerate([], {}).first

        expect(item.metadata["tool"]).to eq("aqua:open-policy-agent/opa")
        expect(item.metadata["argv"]).to eq(["mise", "uninstall", "aqua:open-policy-agent/opa@1.13.2"])
        expect(item.path).to match(Souji::Plan::SYNTHETIC_URI_RE)
      end
    end

    it "measures each install directory, because uninstall removes all of it" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)

        item = recipe.enumerate([], {}).first

        expect(item.size_bytes).to eq(64)
        expect(item.metadata).not_to have_key("size_bytes_upper_bound")
      end
    end

    it "ignores a version mise lists but has nothing on disk for" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)

        expect(recipe.enumerate([], {}).map { |i| i.metadata["tool"] }).not_to include("node")
      end
    end

    it "narrows to the named tools when asked" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)

        items = recipe.enumerate([], tools: ["awscli"])

        expect(items.map { |i| i.metadata["version"] }).to eq(%w[2.30.0 2.35.12])
      end
    end

    it "accepts a single tool name as well as a list" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)

        expect(recipe.enumerate([], tools: "awscli").size).to eq(2)
      end
    end

    it "proposes nothing when mise reports nothing prunable" do
      with_tmp_dir do |tmp|
        stub_mise(tmp, json: mise_ls_prunable_empty)

        expect(recipe.enumerate([], {})).to eq([])
      end
    end

    it "proposes nothing when mise cannot be queried" do
      stub_external("mise", "ls", "--prunable", stdout: "", exitstatus: 1)

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "never runs a mutating command while planning, not even mise prune --dry-run" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)

        recipe.enumerate([], {})

        expect_only_read_only_calls!
        expect(external_calls.flatten).not_to include("prune")
      end
    end
  end

  describe "#verify" do
    it "accepts a version that is still prunable" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)

        expect(recipe.verify(recipe.enumerate([], {}).first)).to eq(:ok)
      end
    end

    it "skips a version a tracked config has started referencing again" do
      # The load-bearing re-check: what counts as prunable depends on the
      # config files mise has tracked, and opening an old project between
      # plan and apply legitimately revokes the item.
      with_tmp_dir do |tmp|
        stub_mise(tmp)
        item = recipe.enumerate([], {}).find { |i| i.metadata["tool"] == "awscli" }
        stub_external("mise", "ls", "--prunable", stdout: mise_ls_prunable_empty)

        expect(recipe.verify(item).last).to match(/no longer prunable/)
      end
    end

    it "skips once the install directory has gone" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)
        item = recipe.enumerate([], {}).first
        FileUtils.remove_entry(item.metadata["install_path"])

        expect(recipe.verify(item).last).to match(/no longer exists/)
      end
    end
  end

  describe "#delete" do
    it "uninstalls exactly that one version" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)
        item = recipe.enumerate([], {}).find { |i| i.metadata["version"] == "2.30.0" }
        stub_external("mise", "uninstall", stdout: "")

        expect(recipe.delete(item)).to eq(:deleted)
        expect(external_calls).to include(%w[mise uninstall awscli@2.30.0])
      end
    end

    it "reports the tool's own failure message" do
      with_tmp_dir do |tmp|
        stub_mise(tmp)
        item = recipe.enumerate([], {}).first
        stub_external("mise", "uninstall", stderr: "mise ERROR tool not installed\n", exitstatus: 1)

        expect(recipe.delete(item)).to match([:failed, /tool not installed/])
      end
    end
  end
end
