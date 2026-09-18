# frozen_string_literal: true

require "souji/recipes/docker_container"

RSpec.describe Souji::Recipes::DockerContainer do
  let(:recipe) { described_class.new }

  before do
    Souji::External::Docker.reset!
    stub_host_os("linux-gnu")
    stub_external("docker", "info", stdout: docker_info_native_json)
  end

  after { Souji::External::Docker.reset! }

  def stub_ps(json = docker_ps_terminal_json)
    stub_external("docker", "ps", stdout: json)
  end

  describe "class-level declarations" do
    it "registers under 'docker-container', requires docker, and is scope-free" do
      expect(described_class.recipe_name).to eq("docker-container")
      expect(described_class.required_external_commands).to eq(["docker"])
      expect(described_class.scope_free?).to be true
      expect(described_class.param_names).to eq([:older_than_days])
    end
  end

  describe "#enumerate" do
    it "proposes one item per terminal container, sorted, with synthetic URIs" do
      stub_ps

      items = recipe.enumerate([], {})

      expect(items.map { |i| i.metadata["name"] }).to eq(%w[old-redis dsql-support-pg16-1])
      expect(items.map(&:path)).to all match(Souji::Plan::SYNTHETIC_URI_RE)
      expect(items.map { |i| i.metadata["state"] }).to eq(%w[exited created])
    end

    it "reports the writable layer as the size, not the virtual size" do
      # docker prints "625kB (virtual 45.7MB)". `docker rm` frees only the
      # writable layer; the image layers are shared. Reading the wrong
      # figure overstates this container by a factor of 73.
      stub_ps

      redis = recipe.enumerate([], {}).find { |i| i.metadata["name"] == "old-redis" }

      expect(redis.size_bytes).to eq(625_000)
      expect(redis.metadata["virtual_size_bytes"]).to eq(45_700_000)
      expect(redis.reason).to match(/only its writable layer is freed/)
    end

    it "asks docker only for terminal states" do
      stub_ps

      recipe.enumerate([], {})

      argv = external_calls.find { |call| call[1] == "ps" }
      expect(argv).to include("status=exited", "status=created", "status=dead")
      expect(argv).to include("--size")
    end

    it "filters out a running container in Ruby even if docker hands one back" do
      # Belt and braces: a docker release that loosened its filter
      # semantics still cannot get a live container into a plan.
      stub_ps(docker_ps_with_running_json)

      items = recipe.enumerate([], {})

      expect(items.map { |i| i.metadata["name"] }).to eq(["old-redis"])
    end

    it "filters on age when asked" do
      stub_ps

      items = recipe.enumerate([], older_than_days: 30)

      expect(items.map { |i| i.metadata["name"] }).to eq(["old-redis"])
    end

    it "returns nothing when there are no stopped containers" do
      stub_ps("")

      expect(recipe.enumerate([], {})).to eq([])
    end

    it "asks for the slow probe budget, because --size makes the daemon walk trees" do
      stub_ps
      allow(Souji::External::Command).to receive(:run).and_call_original

      recipe.enumerate([], {})

      expect(Souji::External::Command).to have_received(:run)
        .with("docker", "ps", "-a", any_args,
              timeout: Souji::External::Command::SLOW_PROBE_TIMEOUT)
    end

    it "says so on stderr when the probe fails, rather than quietly proposing nothing" do
      # An empty plan and a timed-out probe look identical otherwise.
      stub_external("docker", "ps", stdout: "", exitstatus: -1, timed_out: true)
      progress = instance_double(Souji::Progress)
      allow(progress).to receive(:scanning)
      allow(progress).to receive(:note)
      recipe.progress = progress

      expect(recipe.enumerate([], {})).to eq([])
      expect(progress).to have_received(:note).with(/docker ps timed out/)
    end

    it "never runs a mutating command while planning" do
      stub_ps

      recipe.enumerate([], {})

      expect_only_read_only_calls!
    end

    it "flags the items when the daemon runs in a VM" do
      Souji::External::Docker.reset!
      stub_host_os("darwin24")
      stub_external("docker", "info", stdout: docker_info_vm_json)
      stub_ps

      expect(recipe.enumerate([], {}).map { |i| i.metadata["host_space_unaffected"] }).to all be true
    end
  end

  describe "#verify" do
    let(:item) { stub_ps.then { recipe.enumerate([], {}).first } }

    it "accepts a container that is still in a terminal state" do
      subject_item = item
      stub_external("docker", "container", "inspect", stdout: "exited\n")

      expect(recipe.verify(subject_item)).to eq(:ok)
    end

    it "skips a container that has gone" do
      subject_item = item
      stub_external("docker", "container", "inspect", stdout: "",
                                                      stderr: "Error: No such container: x\n", exitstatus: 1)

      expect(recipe.verify(subject_item)).to eq([:skip, "container no longer present"])
    end

    it "does not report a stopped daemon as a missing container" do
      subject_item = item
      stub_external("docker", "container", "inspect", stdout: "",
                                                      stderr: "Cannot connect to the Docker daemon\n",
                                                      exitstatus: 1)

      expect(recipe.verify(subject_item).last).to match(/docker is not answering/)
    end

    it "does not report a timed-out inspect as a missing container" do
      subject_item = item
      stub_external("docker", "container", "inspect", exitstatus: -1, timed_out: true)

      expect(recipe.verify(subject_item)).to eq([:skip, "docker container inspect timed out"])
    end

    it "skips a container that has been started again since planning" do
      # The guarantee against racing a `docker compose up`.
      subject_item = item
      stub_external("docker", "container", "inspect", stdout: "running\n")

      expect(recipe.verify(subject_item)).to eq([:skip, "container is now running"])
    end
  end

  describe "#delete" do
    let(:item) { stub_ps.then { recipe.enumerate([], {}).first } }

    it "runs docker rm without -f and without -v" do
      # -f would kill a container that started since planning; -v would
      # remove volumes that may hold the only copy of a database.
      subject_item = item
      stub_external("docker", "rm", stdout: "removed\n")

      expect(recipe.delete(subject_item)).to eq(:deleted)
      rm_call = external_calls.find { |call| call[1] == "rm" }
      expect(rm_call).to eq(["docker", "rm", subject_item.metadata["container_id"]])
    end

    it "fails rather than forcing when docker refuses" do
      subject_item = item
      stub_external("docker", "rm", stderr: "container is running\n", exitstatus: 1)

      expect(recipe.delete(subject_item)).to match([:failed, /container is running/])
    end

    it "reports a timeout as a failure" do
      subject_item = item
      stub_external("docker", "rm", exitstatus: -1, timed_out: true)

      expect(recipe.delete(subject_item)).to match([:failed, /timed out/])
    end
  end
end
