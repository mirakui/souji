# frozen_string_literal: true

require "souji/recipes/docker_image"

RSpec.describe Souji::Recipes::DockerImage do
  let(:recipe) { described_class.new }

  before { Souji::External::Docker.reset! }

  after { Souji::External::Docker.reset! }

  def stub_dangling(json = docker_image_ls_dangling_json)
    stub_external("docker", "image", "ls", stdout: json)
  end

  describe "class-level declarations" do
    it "registers under 'docker-image'" do
      expect(described_class.recipe_name).to eq("docker-image")
    end

    it "requires the docker external command" do
      expect(described_class.required_external_commands).to eq(["docker"])
    end

    it "declares itself scope-free, because its items are not under any target root" do
      expect(described_class.scope_free?).to be true
    end

    it "declares only older_than_days" do
      expect(described_class.param_names).to eq([:older_than_days])
    end
  end

  describe "#enumerate" do
    it "reads docker's sizes as SI units" do
      # docker prints kB = 1000. Reading them as binary overstated every
      # image by about 7% at GB scale.
      stub_external("docker", "info", stdout: docker_info_native_json)
      stub_dangling

      expect(recipe.enumerate([], {}).map(&:size_bytes)).to eq([479_000_000, 1_200_000_000])
    end

    it "emits synthetic URIs, sorted, and marks the deletion irreversible" do
      stub_external("docker", "info", stdout: docker_info_native_json)
      stub_dangling

      items = recipe.enumerate([], {})

      expect(items.map(&:path)).to eq(["docker-image://sha256:aaaa", "docker-image://sha256:bbbb"])
      expect(items.map(&:path)).to all match(Souji::Plan::SYNTHETIC_URI_RE)
      expect(items.map { |i| i.metadata["irreversible"] }).to all be true
    end

    it "never runs a mutating command while planning" do
      stub_external("docker", "info", stdout: docker_info_native_json)
      stub_dangling

      recipe.enumerate([], {})

      expect_only_read_only_calls!
    end

    it "returns nothing when docker reports no dangling images" do
      stub_external("docker", "info", stdout: docker_info_native_json)
      stub_dangling("")

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "filters on age when asked, and drops images whose age it cannot read" do
      stub_external("docker", "info", stdout: docker_info_native_json)
      unreadable = %({"ID":"sha256:cccc","Size":"1MB","CreatedAt":"not a timestamp"}\n)
      stub_dangling("#{unreadable}#{docker_image_ls_dangling_json}")

      ids = recipe.enumerate([], older_than_days: 60).map { |i| i.metadata["image_id"] }

      expect(ids).to eq(["sha256:aaaa"])
    end

    describe "when the daemon runs in a VM" do
      # Pruning inside a Lima or Docker Desktop VM does not shrink the VM's
      # sparse disk image, so the host's df does not move. Reporting those
      # bytes as freed host space is the one thing souji must not do.
      it "flags every item so the plan can keep the bytes out of the host total" do
        stub_host_os("darwin24")
        stub_external("docker", "info", stdout: docker_info_vm_json)
        stub_dangling

        items = recipe.enumerate([], {})

        expect(items.map { |i| i.metadata["host_space_unaffected"] }).to all be true
        expect(items.first.metadata).to include(
          "daemon_host" => "lima-rancher-desktop", "daemon_os" => "Alpine Linux v3.23"
        )
      end

      it "says so once on stderr at plan time" do
        stub_host_os("darwin24")
        stub_external("docker", "info", stdout: docker_info_vm_json)
        stub_dangling
        progress = instance_double(Souji::Progress)
        allow(progress).to receive(:scanning)
        recipe.progress = progress

        expect(progress).to receive(:note).once.with(/does not free host disk/)

        recipe.enumerate([], {})
      end
    end

    it "does not flag items when the daemon is native to the host" do
      stub_host_os("linux-gnu")
      stub_external("docker", "info", stdout: docker_info_native_json)
      stub_dangling

      metadata = recipe.enumerate([], {}).first.metadata

      expect(metadata).not_to have_key("host_space_unaffected")
      expect(metadata).not_to have_key("daemon_host")
    end
  end

  describe "#verify" do
    let(:item) do
      Souji::PlanItem.new(id: Souji::PlanItem.generate_id("docker-image"), recipe: "docker-image",
                          path: "docker-image://sha256:aaaa", reason: "r",
                          metadata: { "image_id" => "sha256:aaaa" })
    end

    it "accepts an image that is still present and still untagged" do
      stub_external("docker", "image", "inspect", stdout: "[{}]")
      stub_external("docker", "image", "inspect", "--format", stdout: "[]")

      expect(recipe.verify(item)).to eq(:ok)
    end

    it "skips an image that has gone" do
      stub_external("docker", "image", "inspect", stdout: "", stderr: "No such image", exitstatus: 1)

      expect(recipe.verify(item)).to eq([:skip, "image no longer present"])
    end

    it "skips an image that has since been tagged" do
      stub_external("docker", "image", "inspect", stdout: "[{}]")
      stub_external("docker", "image", "inspect", "--format", stdout: %(["app:latest"]))

      expect(recipe.verify(item)).to eq([:skip, "image is now tagged"])
    end
  end

  describe "#delete" do
    let(:item) do
      Souji::PlanItem.new(id: Souji::PlanItem.generate_id("docker-image"), recipe: "docker-image",
                          path: "docker-image://sha256:aaaa", reason: "r",
                          metadata: { "image_id" => "sha256:aaaa" })
    end

    it "reports :deleted, never :trashed, because docker rm is the only mechanism" do
      stub_external("docker", "image", "rm", stdout: "Deleted: sha256:aaaa\n")

      expect(recipe.delete(item)).to eq(:deleted)
    end

    it "reports the tool's own stderr on failure" do
      stub_external("docker", "image", "rm", stderr: "image is being used\n", exitstatus: 1)

      expect(recipe.delete(item)).to match([:failed, /image is being used/])
    end

    it "reports a timeout as a failure rather than hanging the run" do
      stub_external("docker", "image", "rm", exitstatus: -1, timed_out: true)

      expect(recipe.delete(item)).to match([:failed, /timed out/])
    end
  end
end
