# frozen_string_literal: true

require "souji/recipes/docker_build_cache"

RSpec.describe Souji::Recipes::DockerBuildCache do
  let(:recipe) { described_class.new }

  before do
    Souji::External::Docker.reset!
    stub_host_os("linux-gnu")
    stub_external("docker", "info", stdout: docker_info_native_json)
  end

  after { Souji::External::Docker.reset! }

  def stub_df(json = docker_system_df_json)
    stub_external("docker", "system", "df", stdout: json)
  end

  describe "class-level declarations" do
    it "registers under 'docker-build-cache', requires docker, and is scope-free" do
      expect(described_class.recipe_name).to eq("docker-build-cache")
      expect(described_class.required_external_commands).to eq(["docker"])
      expect(described_class.scope_free?).to be true
      expect(described_class.param_names).to eq([:unused_for_days])
    end
  end

  describe "#enumerate" do
    it "takes the size from docker system df's Reclaimable, not from buildx du" do
      # `docker buildx du`'s trailing Reclaimable counts records shared
      # with live images: it reported 13.59 GB where a plain prune frees
      # 8.709 GB. `docker system df` reports what prune actually frees.
      stub_df

      item = recipe.enumerate([], {}).first

      expect(item.size_bytes).to eq(8_709_000_000)
      expect(item.metadata["total_bytes"]).to eq(13_590_000_000)
      expect(item.metadata["size_basis"]).to match(/system df/)
    end

    it "never consults docker buildx du" do
      stub_df

      recipe.enumerate([], {})

      expect(external_calls.flatten).not_to include("buildx")
    end

    it "proposes one opaque item that never passes -a" do
      # -a would discard cache still in use by live images.
      stub_df

      items = recipe.enumerate([], {})

      expect(items.size).to eq(1)
      expect(items.first.path).to eq("docker-build-cache://prune")
      expect(items.first.metadata["argv"]).to eq(%w[docker builder prune -f])
      expect(items.first.metadata["record_count"]).to eq(232)
    end

    it "proposes nothing when there is no reclaimable build cache" do
      stub_df(docker_system_df_no_build_cache)

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "proposes nothing when docker does not report a build cache row at all" do
      stub_df(%({"Type":"Images","Reclaimable":"1GB","Size":"2GB","TotalCount":"3"}\n))

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "never runs a mutating command while planning" do
      stub_df

      recipe.enumerate([], {})

      expect_only_read_only_calls!
    end

    describe "with unused_for_days:" do
      it "adds the filter in hours, which is the unit docker takes" do
        stub_df

        item = recipe.enumerate([], unused_for_days: 30).first

        expect(item.metadata["argv"]).to eq(["docker", "builder", "prune", "-f",
                                             "--filter", "unused-for=720h"])
      end
    end

    it "flags the item when the daemon runs in a VM" do
      Souji::External::Docker.reset!
      stub_host_os("darwin24")
      stub_external("docker", "info", stdout: docker_info_vm_json)
      stub_df

      expect(recipe.enumerate([], {}).first.metadata["host_space_unaffected"]).to be true
    end
  end

  describe "#verify" do
    it "accepts the item while docker still reports reclaimable cache" do
      stub_df

      expect(recipe.verify(recipe.enumerate([], {}).first)).to eq(:ok)
    end

    it "skips once the cache has already been pruned" do
      stub_df
      item = recipe.enumerate([], {}).first
      stub_df(docker_system_df_no_build_cache)

      expect(recipe.verify(item)).to eq([:skip, "docker reports no reclaimable build cache"])
    end
  end

  describe "#delete" do
    it "runs the recorded argv and reports :deleted" do
      stub_df
      item = recipe.enumerate([], {}).first
      stub_external("docker", "builder", "prune", stdout: "Total reclaimed space: 8.709GB\n")

      expect(recipe.delete(item)).to eq(:deleted)
      expect(external_calls).to include(%w[docker builder prune -f])
    end

    it "reports a timeout as a failure, since a prune can run for minutes" do
      stub_df
      item = recipe.enumerate([], {}).first
      stub_external("docker", "builder", "prune", exitstatus: -1, timed_out: true)

      expect(recipe.delete(item)).to match([:failed, /timed out after 900s/])
    end
  end
end
