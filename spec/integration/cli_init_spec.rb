# frozen_string_literal: true

require "fileutils"
require "souji/commands/init_command"

RSpec.describe "souji init (integration)" do
  let(:command) { Souji::Commands::InitCommand.new(stdout: stdout, stderr: stderr) }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:scenario_path) { File.join(ENV.fetch("XDG_CONFIG_HOME"), "souji", "scenario", "default.rb") }

  around do |example|
    saved = ENV.to_hash
    Dir.mktmpdir("souji-init-home-") do |home|
      ENV["HOME"] = home
      ENV["XDG_CONFIG_HOME"] = File.join(home, ".config")
      ENV["XDG_CACHE_HOME"] = File.join(home, ".cache")
      ENV["XDG_STATE_HOME"] = File.join(home, ".local", "state")
      example.run
    end
  ensure
    ENV.replace(saved)
  end

  describe "fresh install" do
    it "creates the scenario directory and the default.rb template" do
      expect(command.call).to eq(0)

      expect(File.file?(scenario_path)).to be true
      expect(stdout.string).to include("created #{scenario_path}")
    end

    it "writes a template that every line is commented out (a no-op scenario)" do
      command.call

      code_lines = File.read(scenario_path).lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
      expect(code_lines).to be_empty
    end

    # A scenario file is read and evaluated as Ruby, so a non-ASCII byte in
    # the template breaks `souji plan` wherever the default external
    # encoding is US-ASCII (LANG unset).
    it "writes an ASCII-only template" do
      command.call

      expect(Souji::Commands::InitCommand::TEMPLATE).to be_ascii_only
    end

    it "writes a template that documents the built-in recipes and the plan/apply flow" do
      command.call
      body = File.read(scenario_path)

      expect(body).to include("target")
      expect(body).to include("git-worktree")
      expect(body).to include("terraform-provider")
      expect(body).to include("docker-image")
      expect(body).to include("souji plan")
      expect(body).to include("souji apply")
    end

    it "produces a template that souji plan can evaluate, yielding an empty plan" do
      command.call

      plan_command = Souji::Commands::PlanCommand.new(stdout: StringIO.new, stderr: StringIO.new)
      expect(plan_command.call).to eq(0)

      out = File.join(ENV.fetch("XDG_CACHE_HOME"), "souji", "default.soujiplan")
      expect(Souji::Plan.load_yaml(out).items).to be_empty
    end
  end

  describe "when default.rb already exists" do
    before do
      FileUtils.mkdir_p(File.dirname(scenario_path))
      File.write(scenario_path, "# hand-written, do not clobber\n")
    end

    it "leaves the file untouched and exits 0" do
      expect(command.call).to eq(0)

      expect(File.read(scenario_path)).to eq("# hand-written, do not clobber\n")
      expect(stdout.string).to include("already exists")
      expect(stdout.string).to include("--force")
    end

    it "overwrites the file when --force is given" do
      expect(command.call(force: true)).to eq(0)

      expect(File.read(scenario_path)).not_to include("hand-written")
      expect(stdout.string).to include("overwrote #{scenario_path}")
    end
  end

  describe "when the scenario directory cannot be created" do
    it "reports the failure and exits 1" do
      blocker = File.join(ENV.fetch("XDG_CONFIG_HOME"), "souji")
      FileUtils.mkdir_p(File.dirname(blocker))
      File.write(blocker, "not a directory")

      expect(command.call).to eq(1)
      expect(stderr.string).to include("[souji]")
    end
  end
end
