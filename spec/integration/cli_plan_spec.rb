# frozen_string_literal: true

require "fileutils"
require "souji/commands/plan_command"

RSpec.describe "souji plan (integration)" do
  let(:command) { Souji::Commands::PlanCommand.new(stdout: stdout, stderr: stderr) }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  around do |example|
    saved = ENV.to_hash
    Dir.mktmpdir("souji-cli-home-") do |home|
      ENV["HOME"] = home
      ENV["XDG_CONFIG_HOME"] = File.join(home, ".config")
      ENV["XDG_CACHE_HOME"] = File.join(home, ".cache")
      ENV["XDG_STATE_HOME"] = File.join(home, ".local", "state")
      saved_registry = Souji::Recipe.registry.dup
      Souji::Recipe.reset_registry!
      Souji::Recipes.load_builtins!
      @home = home
      example.run
    ensure
      Souji::Recipe.reset_registry!
      saved_registry.each { |n, k| Souji::Recipe.register(n, k) }
    end
  ensure
    ENV.replace(saved)
  end

  def install_scenario(name, body)
    dir = File.join(ENV.fetch("XDG_CONFIG_HOME"), "souji", "scenario")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.rb"), body)
  end

  describe "bare-name resolution" do
    it "resolves bare names through XDG_CONFIG_HOME and writes plans to XDG_CACHE_HOME", :git do
      with_tmp_dir do |work|
        repo = build_git_repo(File.join(work, "repo"))
        prunable = add_worktree(repo: repo, wt_path: File.join(work, "wt-1"), branch_name: "feat-1")
        make_worktree_prunable!(prunable)

        install_scenario("weekly", <<~RUBY)
          target "#{work}"
          recipe "git-worktree"
        RUBY

        exit_code = command.call("weekly")
        expect(exit_code).to eq(0)

        out = File.join(ENV.fetch("XDG_CACHE_HOME"), "souji", "weekly.soujiplan")
        expect(File.file?(out)).to be true

        plan = Souji::Plan.load_yaml(out)
        expect(plan.items.map(&:path)).to include(prunable)
        expect(stdout.string).to include("wrote #{out}")
      end
    end
  end

  describe "default scenario" do
    it "falls back to the 'default' scenario when no argument is given", :git do
      with_tmp_dir do |work|
        repo = build_git_repo(File.join(work, "repo"))
        prunable = add_worktree(repo: repo, wt_path: File.join(work, "wt-1"), branch_name: "feat-1")
        make_worktree_prunable!(prunable)

        install_scenario("default", <<~RUBY)
          target "#{work}"
          recipe "git-worktree"
        RUBY

        expect(command.call).to eq(0)

        out = File.join(ENV.fetch("XDG_CACHE_HOME"), "souji", "default.soujiplan")
        expect(Souji::Plan.load_yaml(out).items.map(&:path)).to include(prunable)
      end
    end

    it "exits 2 naming default.rb when no argument is given and no default scenario exists" do
      expect(command.call).to eq(2)
      expected = File.join(ENV.fetch("XDG_CONFIG_HOME"), "souji", "scenario", "default.rb")
      expect(stderr.string).to include(expected)
    end
  end

  describe "progress output" do
    it "reports scenario, recipe and scanned repositories on stderr", :git do
      with_tmp_dir do |work|
        repo = build_git_repo(File.join(work, "repo"))
        prunable = add_worktree(repo: repo, wt_path: File.join(work, "wt-1"), branch_name: "feat-1")
        make_worktree_prunable!(prunable)

        install_scenario("weekly", <<~RUBY)
          target "#{work}"
          recipe "git-worktree"
        RUBY

        expect(command.call("weekly")).to eq(0)

        scenario_path = File.join(ENV.fetch("XDG_CONFIG_HOME"), "souji", "scenario", "weekly.rb")
        expect(stderr.string).to include("[souji] scenario #{scenario_path}")
        expect(stderr.string).to include("[souji] targets: #{work}")
        expect(stderr.string).to include("[souji] [1/1] recipe git-worktree (targets: #{work})")
        expect(stderr.string).to include("[souji]   scanning #{repo}")
        expect(stderr.string).to include("[souji] recipe git-worktree: 1 item")
        # stdout stays reserved for the deliverable one-liner.
        expect(stdout.string.lines.size).to eq(1)
      end
    end

    it "suppresses progress under --quiet while still writing the plan and the summary", :git do
      with_tmp_dir do |work|
        repo = build_git_repo(File.join(work, "repo"))
        prunable = add_worktree(repo: repo, wt_path: File.join(work, "wt-1"), branch_name: "feat-1")
        make_worktree_prunable!(prunable)

        install_scenario("weekly", <<~RUBY)
          target "#{work}"
          recipe "git-worktree"
        RUBY

        expect(command.call("weekly", quiet: true)).to eq(0)
        expect(stderr.string).to eq("")
        expect(stdout.string).to include("wrote ")
      end
    end
  end

  describe "missing scenario" do
    it "exits 2 with stderr listing the path that was tried" do
      exit_code = command.call("nope")
      expect(exit_code).to eq(2)
      expected = File.join(ENV.fetch("XDG_CONFIG_HOME"), "souji", "scenario", "nope.rb")
      expect(stderr.string).to include(expected)
    end
  end

  describe "external command missing" do
    it "skips the affected recipe with stderr warning and continues with others", :git do
      with_tmp_dir do |work|
        # Make a fake recipe that requires a nonexistent binary
        Class.new(Souji::Recipe) do
          recipe_name "needs-fake-bin"
          required_external_commands "definitely-no-such-binary-9876"
          def enumerate(_t, _p) = (raise "should not run")
        end

        repo = build_git_repo(File.join(work, "repo"))
        prunable = add_worktree(repo: repo, wt_path: File.join(work, "wt-1"), branch_name: "feat-1")
        make_worktree_prunable!(prunable)

        install_scenario("mixed", <<~RUBY)
          target "#{work}"
          recipe "needs-fake-bin"
          recipe "git-worktree"
        RUBY

        exit_code = command.call("mixed")
        expect(exit_code).to eq(0)
        expect(stderr.string).to include("needs-fake-bin")
        expect(stderr.string).to include("definitely-no-such-binary-9876")

        out = File.join(ENV.fetch("XDG_CACHE_HOME"), "souji", "mixed.soujiplan")
        plan = Souji::Plan.load_yaml(out)
        expect(plan.items.size).to eq(1)
        expect(plan.items.first.recipe).to eq("git-worktree")
      end
    end
  end

  describe "unknown recipe" do
    it "exits 65 with stderr identifying the unknown recipe" do
      install_scenario("typo", <<~RUBY)
        target "/tmp"
        recipe "git-worktreee"
      RUBY
      exit_code = command.call("typo")
      expect(exit_code).to eq(65)
      expect(stderr.string).to include("git-worktreee")
    end

    it "exits 65 before scanning when a later recipe name is a typo" do
      install_scenario("late-typo", <<~RUBY)
        target "/tmp"
        recipe "git-worktree"
        recipe "git-worktreee"
      RUBY
      expect(command.call("late-typo")).to eq(65)
      expect(stderr.string).to include("git-worktreee")
      expect(stderr.string).not_to include("scanning")
    end
  end

  describe "unknown recipe param" do
    it "exits 65 naming the param and the recipe's declared params" do
      install_scenario("bad-param", <<~RUBY)
        target "/tmp"
        recipe "docker-image", older_than_day: 30
      RUBY
      expect(command.call("bad-param")).to eq(65)
      expect(stderr.string).to include("older_than_day")
      expect(stderr.string).to include("older_than_days")
      expect(stderr.string).not_to include("scanning")
    end
  end

  describe "with_targets with no declared target" do
    it "exits 65 before scanning, naming the target declaration to add" do
      install_scenario("no-target", <<~RUBY)
        with_targets "/tmp" do
          recipe "git-worktree"
        end
      RUBY
      expect(command.call("no-target")).to eq(65)
      expect(stderr.string).to include('add `target "/tmp"`')
      expect(stderr.string).not_to include("scanning")
    end
  end

  describe "scope-escape (anti-pattern fixture)" do
    it "exits 65 when a recipe's targets: escapes the scenario-level target set" do
      install_scenario("escape", <<~RUBY)
        target "/tmp/in"
        recipe "git-worktree", targets: ["/tmp/out"]
      RUBY
      exit_code = command.call("escape")
      expect(exit_code).to eq(65)
      expect(stderr.string).to include("/tmp/out")
    end
  end

  describe "explicit -o override" do
    it "writes the plan to the given path", :git do
      with_tmp_dir do |work|
        repo = build_git_repo(File.join(work, "repo"))
        prunable = add_worktree(repo: repo, wt_path: File.join(work, "wt-1"), branch_name: "feat-1")
        make_worktree_prunable!(prunable)

        install_scenario("weekly", <<~RUBY)
          target "#{work}"
          recipe "git-worktree"
        RUBY

        explicit = File.join(work, "explicit.soujiplan")
        exit_code = command.call("weekly", output: explicit)
        expect(exit_code).to eq(0)
        expect(File.file?(explicit)).to be true
      end
    end
  end
end
