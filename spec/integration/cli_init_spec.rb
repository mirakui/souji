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

  # FR-005a: --force is scoped to overwriting a user-edited regular file. A
  # symlink (dotfiles management) or a stray directory is never clobbered.
  describe "when the destination is not a regular file" do
    before { FileUtils.mkdir_p(File.dirname(scenario_path)) }

    it "refuses a directory with exit 2 and a diagnostic naming the path" do
      FileUtils.mkdir_p(scenario_path)

      expect(command.call).to eq(2)
      expect(stderr.string).to include(scenario_path)
      expect(stderr.string).to include("not a regular file")
      expect(stderr.string).to include("directory")
      expect(File.directory?(scenario_path)).to be true
    end

    it "refuses a directory even with --force" do
      FileUtils.mkdir_p(scenario_path)

      expect(command.call(force: true)).to eq(2)
      expect(File.directory?(scenario_path)).to be true
    end

    it "refuses a symlink without following it, with and without --force" do
      real = File.join(Dir.home, "dotfiles-default.rb")
      File.write(real, "# managed by dotfiles\n")
      File.symlink(real, scenario_path)

      expect(command.call).to eq(2)
      expect(command.call(force: true)).to eq(2)

      expect(File.symlink?(scenario_path)).to be true
      expect(File.read(real)).to eq("# managed by dotfiles\n")
      expect(stderr.string).to include("symbolic link")
    end
  end

  # FR-011: a half-written scenario file would make `souji plan` fail with a
  # SyntaxError, so the destination is replaced via rename(2).
  describe "atomic write" do
    it "leaves no temporary files behind on success" do
      command.call

      leftovers = Dir.children(File.dirname(scenario_path)) - ["default.rb"]
      expect(leftovers).to be_empty
    end

    it "keeps the previous content and removes the temp file when writing fails" do
      FileUtils.mkdir_p(File.dirname(scenario_path))
      File.write(scenario_path, "# previous content\n")

      allow(File).to receive(:rename).and_raise(Errno::ENOSPC)

      expect(command.call(force: true)).to eq(1)
      expect(File.read(scenario_path)).to eq("# previous content\n")
      expect(Dir.children(File.dirname(scenario_path))).to eq(["default.rb"])
      expect(stderr.string).to include("[souji]")
    end
  end

  # FR-010: init owns the scenario directory and nothing else.
  describe "blast radius" do
    it "does not create the cache or state directories" do
      command.call

      expect(Dir.exist?(File.join(ENV.fetch("XDG_CACHE_HOME"), "souji"))).to be false
      expect(Dir.exist?(File.join(ENV.fetch("XDG_STATE_HOME"), "souji"))).to be false
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
