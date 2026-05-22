# frozen_string_literal: true

require "fileutils"
require "souji/commands/plan_command"

# US3: scenarios composed in the Ruby DSL exercise with_targets,
# recipe-specific keyword params, and programmatic target enumeration.
RSpec.describe "DSL composition (US3 integration)" do
  let(:plan_command) { Souji::Commands::PlanCommand.new(stdout: stdout, stderr: stderr) }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  around do |example|
    saved = ENV.to_hash
    Dir.mktmpdir("souji-us3-home-") do |home|
      ENV["HOME"] = home
      ENV["XDG_CONFIG_HOME"] = File.join(home, ".config")
      ENV["XDG_CACHE_HOME"] = File.join(home, ".cache")
      saved_registry = Souji::Recipe.registry.dup
      Souji::Recipe.reset_registry!
      Souji::Recipes.load_builtins!
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

  describe "with_targets block scopes recipes to a narrower target subset", :git do
    it "limits a recipe inside with_targets to the block's targets" do
      with_tmp_dir do |work|
        # Two targets: work/in and work/out. We'll put git-worktree on both,
        # but with_targets scopes it to "in" only.
        repo_in = build_git_repo(File.join(work, "in", "repo"))
        repo_out = build_git_repo(File.join(work, "out", "repo"))
        pi_in  = add_worktree(repo: repo_in,  wt_path: File.join(work, "in",  "wt"), branch_name: "feat-in")
        pi_out = add_worktree(repo: repo_out, wt_path: File.join(work, "out", "wt"), branch_name: "feat-out")
        make_worktree_prunable!(pi_in)
        make_worktree_prunable!(pi_out)

        install_scenario("scoped", <<~RUBY)
          target "#{File.join(work, "in")}"
          target "#{File.join(work, "out")}"
          with_targets "#{File.join(work, "in")}" do
            recipe "git-worktree"
          end
        RUBY

        rc = plan_command.call("scoped")
        expect(rc).to eq(0)
        plan = Souji::Plan.load_yaml(File.join(ENV.fetch("XDG_CACHE_HOME"), "souji", "scoped.soujiplan"))
        paths = plan.items.map(&:path)
        expect(paths).to include(pi_in)
        expect(paths).not_to include(pi_out)
      end
    end
  end

  describe "recipe-specific keyword params reach Recipe#enumerate", :git do
    it "passes kwargs through the DSL to the recipe's params hash" do
      captured = nil
      Souji::Recipe.reset_registry!
      capture_recipe = Class.new(Souji::Recipe) do
        recipe_name "capture-params"
        define_method(:enumerate) do |_target_roots, params|
          captured = params
          []
        end
      end
      _ = capture_recipe

      with_tmp_dir do |work|
        install_scenario("params", <<~RUBY)
          target "#{work}"
          recipe "capture-params", older_than_days: 30, retain: 5
        RUBY
        rc = plan_command.call("params")
        expect(rc).to eq(0)
      end
      expect(captured).to eq(older_than_days: 30, retain: 5)
    end
  end

  describe "programmatic target enumeration via plain Ruby", :git do
    it "supports Dir.glob in scenarios for dynamic targets" do
      with_tmp_dir do |oss_root|
        2.times do |i|
          repo = build_git_repo(File.join(oss_root, "proj-#{i}"))
          add_worktree(repo: repo, wt_path: File.join(oss_root, "proj-#{i}", "wt"), branch_name: "feat-#{i}")
            .tap { |p| make_worktree_prunable!(p) }
        end

        install_scenario("multi", <<~RUBY)
          Dir.glob(File.join("#{oss_root}", "*/.git")).each do |git_dir|
            target File.dirname(git_dir)
          end
          recipe "git-worktree"
        RUBY

        rc = plan_command.call("multi")
        expect(rc).to eq(0)
        plan = Souji::Plan.load_yaml(File.join(ENV.fetch("XDG_CACHE_HOME"), "souji", "multi.soujiplan"))
        expect(plan.items.size).to eq(2)
        plan.items.each { |item| expect(item.recipe).to eq("git-worktree") }
      end
    end
  end

  describe "anti-pattern: unknown recipe" do
    it "exits 65 and stderr names the offending recipe" do
      install_scenario("typo", <<~RUBY)
        target "/tmp"
        recipe "git-worktreee"
      RUBY
      rc = plan_command.call("typo")
      expect(rc).to eq(65)
      expect(stderr.string).to include("git-worktreee")
      expect(stderr.string).to include("git-worktree") # listed as available
    end
  end

  describe "anti-pattern: scope-escape via per-recipe targets:" do
    it "exits 65 and stderr identifies the offending recipe call" do
      install_scenario("escape", <<~RUBY)
        target "/tmp/in"
        recipe "git-worktree", targets: ["/tmp/out"]
      RUBY
      rc = plan_command.call("escape")
      expect(rc).to eq(65)
      expect(stderr.string).to include("/tmp/out")
      expect(stderr.string).to include("escape")
    end
  end
end
