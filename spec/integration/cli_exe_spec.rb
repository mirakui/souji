# frozen_string_literal: true

require "open3"

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
end
