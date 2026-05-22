# frozen_string_literal: true

require "fileutils"
require "souji/recipes/terraform_provider"

RSpec.describe Souji::Recipes::TerraformProvider do
  let(:recipe) { described_class.new }

  describe "class-level declarations" do
    it "registers under 'terraform-provider'" do
      expect(described_class.recipe_name).to eq("terraform-provider")
    end

    it "declares no required external commands (pure filesystem)" do
      expect(described_class.required_external_commands).to eq([])
    end
  end

  describe "#enumerate" do
    def write_lockfile(dir, provider:, version:)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ".terraform.lock.hcl"), <<~HCL)
        provider "registry.terraform.io/hashicorp/#{provider}" {
          version = "#{version}"
        }
      HCL
    end

    def make_cache_entry(cache_root:, namespace:, provider:, version:)
      dir = File.join(cache_root, "registry.terraform.io", namespace, provider, version, "darwin_arm64")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "terraform-provider-#{provider}_v#{version}"), "binary-stub")
      dir
    end

    it "flags cache entries not referenced by any .terraform.lock.hcl under target_roots" do
      with_tmp_dir do |dir|
        cache_root = File.join(dir, "plugin-cache")
        target_dir = File.join(dir, "work")
        write_lockfile(target_dir, provider: "aws", version: "4.55.0")
        write_lockfile(File.join(target_dir, "subproject"), provider: "random", version: "3.5.0")

        unreferenced_aws_450 = make_cache_entry(cache_root: cache_root, namespace: "hashicorp",
                                                provider: "aws", version: "4.50.0")
        referenced_aws_455   = make_cache_entry(cache_root: cache_root, namespace: "hashicorp",
                                                provider: "aws", version: "4.55.0")
        unreferenced_random_340 = make_cache_entry(cache_root: cache_root, namespace: "hashicorp",
                                                   provider: "random", version: "3.4.0")
        referenced_random_350   = make_cache_entry(cache_root: cache_root, namespace: "hashicorp",
                                                   provider: "random", version: "3.5.0")

        items = recipe.enumerate([target_dir], plugin_cache_dir: cache_root)
        paths = items.map(&:path)
        expect(paths).to include(unreferenced_aws_450, unreferenced_random_340)
        expect(paths).not_to include(referenced_aws_455, referenced_random_350)
        items.each do |item|
          expect(item.recipe).to eq("terraform-provider")
          expect(item.metadata["provider"]).to(satisfy { |p| %w[aws random].include?(p) })
        end
      end
    end

    it "returns an empty array when every cache entry is referenced" do
      with_tmp_dir do |dir|
        cache_root = File.join(dir, "plugin-cache")
        target_dir = File.join(dir, "work")
        write_lockfile(target_dir, provider: "aws", version: "4.55.0")
        make_cache_entry(cache_root: cache_root, namespace: "hashicorp",
                         provider: "aws", version: "4.55.0")

        items = recipe.enumerate([target_dir], plugin_cache_dir: cache_root)
        expect(items).to eq([])
      end
    end

    it "returns deterministic ordering across runs" do
      with_tmp_dir do |dir|
        cache_root = File.join(dir, "plugin-cache")
        target_dir = File.join(dir, "work")
        write_lockfile(target_dir, provider: "aws", version: "4.55.0")
        %w[4.50.0 4.51.0 4.52.0].each do |v|
          make_cache_entry(cache_root: cache_root, namespace: "hashicorp",
                           provider: "aws", version: v)
        end
        a = recipe.enumerate([target_dir], plugin_cache_dir: cache_root).map(&:path)
        b = recipe.enumerate([target_dir], plugin_cache_dir: cache_root).map(&:path)
        expect(a).to eq(b)
      end
    end
  end
end
