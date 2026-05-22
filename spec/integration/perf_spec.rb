# frozen_string_literal: true

require "souji/commands/plan_command"

# Light performance smoke per plan.md Performance Goals: a synthetic
# workstation tree with multiple git repos + worktrees must complete
# `souji plan` in under 30 seconds wall-clock. Tagged :perf and skipped
# by default because it builds many real git repos.
RSpec.describe "Performance smoke", :perf, :git do
  around do |example|
    saved = ENV.to_hash
    Dir.mktmpdir("souji-perf-home-") do |home|
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

  it "plans 20 git repos × 2 prunable worktrees each within 30s" do
    with_tmp_dir do |work|
      20.times do |i|
        repo = build_git_repo(File.join(work, "proj-#{i}"))
        2.times do |j|
          wt = add_worktree(repo: repo, wt_path: File.join(work, "proj-#{i}", "wt-#{j}"),
                            branch_name: "feat-#{i}-#{j}")
          make_worktree_prunable!(wt)
        end
      end

      dir = File.join(ENV.fetch("XDG_CONFIG_HOME"), "souji", "scenario")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "perf.rb"), <<~RUBY)
        target "#{work}"
        recipe "git-worktree"
      RUBY

      started = Time.now
      rc = Souji::Commands::PlanCommand.new(stdout: StringIO.new, stderr: StringIO.new).call("perf")
      elapsed = Time.now - started

      expect(rc).to eq(0)
      expect(elapsed).to be < 30, "souji plan took #{elapsed.round(2)}s (limit 30s)"

      plan = Souji::Plan.load_yaml(File.join(ENV.fetch("XDG_CACHE_HOME"), "souji", "perf.soujiplan"))
      expect(plan.items.size).to eq(40)
    end
  end
end
