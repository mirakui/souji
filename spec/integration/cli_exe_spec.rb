# frozen_string_literal: true

require "open3"
require "tmpdir"

# Exercises the real exe/souji entrypoint as a subprocess so we catch
# wiring bugs that the in-process command specs (which require "souji"
# via spec_helper and thus register all autoloads) cannot reproduce.
RSpec.describe "exe/souji (subprocess)" do
  let(:exe) { File.expand_path("../../exe/souji", __dir__) }

  # Strip every channel Bundler uses to inject the source checkout onto the
  # subprocess load path (RUBYOPT/RUBYLIB preloads plus the BUNDLER_SETUP hook
  # RubyGems honours). With those gone, and no -I lib, the executable only
  # runs if it puts its own lib on the load path itself.
  let(:clean_env) do
    {
      "RUBYOPT" => nil,
      "RUBYLIB" => nil,
      "BUNDLER_SETUP" => nil,
      "BUNDLE_GEMFILE" => nil,
      "BUNDLE_BIN_PATH" => nil
    }
  end

  def run(*)
    Open3.capture3(clean_env, RbConfig.ruby, exe, *)
  end

  it "prints version" do
    stdout, stderr, status = run("version")
    expect(status.success?).to be(true), "stderr: #{stderr}"
    expect(stdout).to include("souji ")
  end

  it "lists registered recipes" do
    stdout, stderr, status = run("recipes")
    expect(status.success?).to be(true), "stderr: #{stderr}"
    expect(stdout).to include("git-worktree")
    expect(stdout).to include("docker-image")
    expect(stdout).to include("terraform-provider")
  end

  it "lists each recipe's declared options under it" do
    stdout, stderr, status = run("recipes")
    expect(status.success?).to be(true), "stderr: #{stderr}"
    expect(stdout).to include("older_than_days:")
    expect(stdout).to include("plugin_cache_dir:")
  end

  # `init` and the bare `plan` / `apply` forms are the first-run path, so they
  # get exercised end-to-end against a throwaway XDG_CONFIG_HOME.
  describe "first-run flow" do
    around do |example|
      Dir.mktmpdir("souji-exe-home-") do |home|
        @home = home
        example.run
      end
    end

    def run_in_home(*)
      env = clean_env.merge(
        "HOME" => @home,
        "XDG_CONFIG_HOME" => File.join(@home, ".config"),
        "XDG_CACHE_HOME" => File.join(@home, ".cache"),
        "XDG_STATE_HOME" => File.join(@home, ".local", "state")
      )
      Open3.capture3(env, RbConfig.ruby, exe, *)
    end

    it "generates the default scenario template with `souji init`" do
      stdout, stderr, status = run_in_home("init")
      expect(status.success?).to be(true), "stderr: #{stderr}"

      scenario = File.join(@home, ".config", "souji", "scenario", "default.rb")
      expect(File.file?(scenario)).to be true
      expect(stdout).to include(scenario)
    end

    it "runs `souji plan` with no argument against the generated default scenario" do
      _out, stderr, status = run_in_home("init")
      expect(status.success?).to be(true), "stderr: #{stderr}"

      stdout, stderr, status = run_in_home("plan")
      expect(status.success?).to be(true), "stderr: #{stderr}"
      expect(stdout).to include(File.join(@home, ".cache", "souji", "default.soujiplan"))
    end

    it "runs `souji apply` with no argument against the generated default plan" do
      run_in_home("init")
      run_in_home("plan")

      stdout, stderr, status = run_in_home("apply", "--yes")
      expect(status.success?).to be(true), "stderr: #{stderr}"
      expect(stdout).to include(File.join(@home, ".cache", "souji", "default.soujiplan"))
    end
  end
end
