# frozen_string_literal: true

require "souji/paths"
require "fileutils"
require "tmpdir"

RSpec.describe Souji::Paths do
  let(:home) { Dir.mktmpdir("souji-home-") }

  around do |example|
    saved = ENV.to_hash
    ENV["HOME"] = home
    ENV.delete("XDG_CONFIG_HOME")
    ENV.delete("XDG_CACHE_HOME")
    ENV.delete("XDG_STATE_HOME")
    example.run
  ensure
    ENV.replace(saved)
    FileUtils.remove_entry(home)
  end

  describe ".path_shaped?" do
    it "returns true when the argument contains a path separator" do
      expect(described_class.path_shaped?("./weekly.rb")).to be true
      expect(described_class.path_shaped?("/abs/path")).to be true
      expect(described_class.path_shaped?("sub/dir")).to be true
    end

    it "returns true when the argument starts with a tilde" do
      expect(described_class.path_shaped?("~/weekly.rb")).to be true
      expect(described_class.path_shaped?("~user/weekly.rb")).to be true
    end

    it "returns true when the argument ends with .rb or .soujiplan" do
      expect(described_class.path_shaped?("weekly.rb")).to be true
      expect(described_class.path_shaped?("weekly.soujiplan")).to be true
    end

    it "returns false for bare names" do
      expect(described_class.path_shaped?("weekly")).to be false
      expect(described_class.path_shaped?("my-cleanup")).to be false
    end
  end

  describe "default XDG directories" do
    it "uses ~/.config when XDG_CONFIG_HOME is unset" do
      expect(described_class.config_home).to eq(File.join(home, ".config"))
    end

    it "uses ~/.cache when XDG_CACHE_HOME is unset" do
      expect(described_class.cache_home).to eq(File.join(home, ".cache"))
    end

    it "uses ~/.local/state when XDG_STATE_HOME is unset" do
      expect(described_class.state_home).to eq(File.join(home, ".local", "state"))
    end

    it "honors XDG_CONFIG_HOME when set" do
      ENV["XDG_CONFIG_HOME"] = "/tmp/cfg"
      expect(described_class.config_home).to eq("/tmp/cfg")
    end

    it "honors XDG_CACHE_HOME when set" do
      ENV["XDG_CACHE_HOME"] = "/tmp/cache"
      expect(described_class.cache_home).to eq("/tmp/cache")
    end

    it "honors XDG_STATE_HOME when set" do
      ENV["XDG_STATE_HOME"] = "/tmp/state"
      expect(described_class.state_home).to eq("/tmp/state")
    end
  end

  describe ".scenario_dir / .cache_dir / .log_dir" do
    it "exposes souji-namespaced subdirectories under each XDG root" do
      expect(described_class.scenario_dir).to eq(File.join(home, ".config", "souji", "scenario"))
      expect(described_class.cache_dir).to eq(File.join(home, ".cache", "souji"))
      expect(described_class.log_dir).to eq(File.join(home, ".local", "state", "souji", "log"))
    end
  end

  describe ".resolve_scenario" do
    it "treats a bare name as a lookup under scenario_dir with .rb appended" do
      scenario = File.join(home, ".config", "souji", "scenario", "weekly.rb")
      FileUtils.mkdir_p(File.dirname(scenario))
      File.write(scenario, "")

      expect(described_class.resolve_scenario("weekly")).to eq(scenario)
    end

    it "uses the argument as a filesystem path when path-shaped" do
      file = File.join(home, "ad-hoc.rb")
      File.write(file, "")
      expect(described_class.resolve_scenario(file)).to eq(file)
    end

    it "raises Souji::ScenarioNotFoundError when bare name does not exist" do
      expect { described_class.resolve_scenario("missing") }
        .to raise_error(Souji::ScenarioNotFoundError) do |err|
          expect(err.message).to include(File.join(home, ".config", "souji", "scenario", "missing.rb"))
        end
    end

    it "raises Souji::ScenarioNotFoundError when a path-shaped argument does not exist" do
      expect { described_class.resolve_scenario("./nope.rb") }
        .to raise_error(Souji::ScenarioNotFoundError) do |err|
          expect(err.message).to include("nope.rb")
        end
    end
  end

  describe ".resolve_plan" do
    it "treats a bare name as a lookup under cache_dir with .soujiplan appended" do
      plan = File.join(home, ".cache", "souji", "weekly.soujiplan")
      FileUtils.mkdir_p(File.dirname(plan))
      File.write(plan, "")
      expect(described_class.resolve_plan("weekly")).to eq(plan)
    end

    it "uses the argument as a filesystem path when path-shaped" do
      file = File.join(home, "out.soujiplan")
      File.write(file, "")
      expect(described_class.resolve_plan(file)).to eq(file)
    end

    it "raises Souji::PlanNotFoundError when bare name does not exist" do
      expect { described_class.resolve_plan("missing") }
        .to raise_error(Souji::PlanNotFoundError) do |err|
          expect(err.message).to include(File.join(home, ".cache", "souji", "missing.soujiplan"))
        end
    end
  end

  describe ".default_plan_output_for" do
    it "uses bare-name basename under cache_dir for bare-name scenarios" do
      expect(described_class.default_plan_output_for("weekly"))
        .to eq(File.join(home, ".cache", "souji", "weekly.soujiplan"))
    end

    it "uses path-stripped basename for path-shaped scenarios" do
      expect(described_class.default_plan_output_for("~/cleanups/weekly.rb"))
        .to eq(File.join(home, ".cache", "souji", "weekly.soujiplan"))
    end
  end

  describe ".default_log_file_for" do
    it "uses log_dir with UTC timestamp and plan basename" do
      now = Time.utc(2026, 5, 22, 13, 50, 0)
      path = described_class.default_log_file_for(plan_path: "/some/where/weekly.soujiplan", now: now)
      expect(path).to eq(File.join(home, ".local", "state", "souji", "log", "2026-05-22T13-50-00Z-weekly.jsonl"))
    end
  end

  describe ".ensure_cache_dir! / .ensure_log_dir!" do
    it "creates the cache directory on demand" do
      described_class.ensure_cache_dir!
      expect(Dir.exist?(File.join(home, ".cache", "souji"))).to be true
    end

    it "creates the log directory on demand" do
      described_class.ensure_log_dir!
      expect(Dir.exist?(File.join(home, ".local", "state", "souji", "log"))).to be true
    end

    it "does not auto-create the scenario directory" do
      # Verify the contract that scenario_dir is NEVER auto-created.
      expect(described_class).not_to respond_to(:ensure_scenario_dir!)
    end
  end
end
