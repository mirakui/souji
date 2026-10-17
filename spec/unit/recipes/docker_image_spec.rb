# frozen_string_literal: true

require "souji/recipes/docker_image"

RSpec.describe Souji::Recipes::DockerImage do
  let(:recipe) { described_class.new }

  before { Souji::External::Docker.reset! }

  after { Souji::External::Docker.reset! }

  def stub_dangling(json = docker_image_ls_dangling_json, containers: {})
    stub_external("docker", "image", "ls", stdout: json)
    stub_containers(containers)
  end

  # containers: { container_id => image_id }, in any state -- docker ps -a
  # does not distinguish, and neither does `docker image rm`.
  def stub_containers(containers)
    stub_external("docker", "ps", "-a", "-q", "--no-trunc", stdout: containers.keys.map { |c| "#{c}\n" }.join)
    stub_external("docker", "container", "inspect", "--format", "{{.Image}}",
                  stdout: containers.values.map { |i| "#{i}\n" }.join)
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

    describe "container ancestry" do
      # docker's `dangling=true` means only "untagged". An untagged image a
      # stopped container was created from is still listed, and
      # `docker image rm` refuses it -- which is how a scenario declaring
      # docker-image before docker-container failed at apply.
      it "excludes images a stopped or created container was made from" do
        stub_external("docker", "info", stdout: docker_info_native_json)
        stub_dangling(containers: { "5fe2176147fc" => "sha256:aaaa" })

        ids = recipe.enumerate([], {}).map { |i| i.metadata["image_id"] }

        expect(ids).to eq(["sha256:bbbb"])
      end

      it "looks at containers in every state, not just running ones" do
        stub_external("docker", "info", stdout: docker_info_native_json)
        stub_dangling

        recipe.enumerate([], {})

        expect(external_calls).to include(%w[docker ps -a -q --no-trunc])
      end

      it "proposes nothing when it cannot list containers, rather than guessing" do
        stub_external("docker", "info", stdout: docker_info_native_json)
        stub_external("docker", "image", "ls", stdout: docker_image_ls_dangling_json)
        stub_external("docker", "ps", "-a", "-q", "--no-trunc", stderr: "daemon gone", exitstatus: 1)
        stub_host_os("linux-gnu")
        progress = instance_double(Souji::Progress, scanning: nil)
        recipe.progress = progress

        expect(progress).to receive(:note).with(/cannot rule out container ancestry/)
        expect(recipe.enumerate([], {})).to eq([])
      end

      it "proposes nothing when inspecting the containers fails" do
        stub_external("docker", "info", stdout: docker_info_native_json)
        stub_external("docker", "image", "ls", stdout: docker_image_ls_dangling_json)
        stub_external("docker", "ps", "-a", "-q", "--no-trunc", stdout: "c1\n")
        stub_external("docker", "container", "inspect", exitstatus: -1, timed_out: true)

        expect(recipe.enumerate([], {})).to eq([])
      end

      it "does not ask about containers when there are no dangling images" do
        stub_external("docker", "info", stdout: docker_info_native_json)
        stub_dangling("")

        recipe.enumerate([], {})

        expect(external_calls).not_to include(%w[docker ps -a -q --no-trunc])
      end
    end

    it "filters on age when asked, and drops images whose age it cannot read" do
      # Pinned: the fixture's newer image ages past any threshold against
      # the real clock.
      allow(Time).to receive(:now).and_return(Time.new(2026, 9, 20, 0, 0, 0, "+09:00"))
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

    def stub_present_untagged
      stub_external("docker", "image", "inspect", stdout: "[{}]")
      stub_external("docker", "image", "inspect", "--format", stdout: "[]")
    end

    it "accepts an image that is still present, still untagged and used by no container" do
      stub_present_untagged
      stub_external("docker", "ps", "-a", "-q", "--no-trunc", "--filter", "ancestor=sha256:aaaa", stdout: "")

      expect(recipe.verify(item)).to eq(:ok)
    end

    it "skips an image a container has been created from since planning" do
      stub_present_untagged
      stub_external("docker", "ps", "-a", "-q", "--no-trunc", "--filter", "ancestor=sha256:aaaa",
                    stdout: "5fe2176147fc0123456789\n")

      expect(recipe.verify(item)).to eq([:skip, "image is used by 1 container(s) (5fe2176147fc)"])
    end

    it "skips rather than deletes when it cannot check container ancestry" do
      stub_present_untagged
      stub_external("docker", "ps", "-a", "-q", "--no-trunc", "--filter", "ancestor=sha256:aaaa",
                    stderr: "Cannot connect to the Docker daemon", exitstatus: 1)

      expect(recipe.verify(item)).to match([:skip, /could not check container ancestry: Cannot connect/])
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
      stub_external("docker", "image", "rm", stderr: "no space left on device\n", exitstatus: 1)

      expect(recipe.delete(item)).to match([:failed, /docker image rm failed: no space left/])
    end

    it "skips, not fails, when a container still uses the image" do
      # The race verify narrows but cannot close.
      stub_external("docker", "image", "rm", exitstatus: 1, stderr: <<~ERR)
        Error response from daemon: conflict: unable to delete ed134ce8cc30 (must be forced) - image is being used by stopped container 5fe2176147fc
      ERR

      expect(recipe.delete(item)).to match([:skip, /image is in use by a container: .*stopped container 5fe2176147fc/])
    end

    it "reports a timeout as a failure rather than hanging the run" do
      stub_external("docker", "image", "rm", exitstatus: -1, timed_out: true)

      expect(recipe.delete(item)).to match([:failed, /timed out/])
    end
  end
end
