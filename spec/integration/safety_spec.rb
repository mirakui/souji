# frozen_string_literal: true

require "digest"
require "find"
require "souji/commands/plan_command"

RSpec.describe "Safety invariants" do
  describe "plan is read-only under target_roots (FR-008, SC-003)" do
    it "produces a plan without modifying any file under target_roots", :git do
      with_tmp_dir do |work|
        repo = build_git_repo(File.join(work, "repo"))
        active = add_worktree(repo: repo, wt_path: File.join(work, "wt-active"), branch_name: "feat-active")
        prunable = add_worktree(repo: repo, wt_path: File.join(work, "wt-pr"), branch_name: "feat-pr")
        make_worktree_prunable!(prunable)

        before_hashes = snapshot_hashes(active)

        with_tmp_xdg(work) do
          install_scenario("ro", <<~RUBY)
            target "#{work}"
            recipe "git-worktree"
          RUBY
          rc = Souji::Commands::PlanCommand.new(
            stdout: StringIO.new, stderr: StringIO.new
          ).call("ro")
          expect(rc).to eq(0)
        end

        after_hashes = snapshot_hashes(active)
        expect(after_hashes).to eq(before_hashes)
      end
    end
  end

  def snapshot_hashes(root)
    out = {}
    Find.find(root) do |path|
      next unless File.file?(path)

      out[path] = Digest::SHA256.file(path).hexdigest
    rescue Errno::EACCES, Errno::ENOENT
      next
    end
    out
  end

  def with_tmp_xdg(_work)
    saved = ENV.to_hash
    Dir.mktmpdir("souji-safety-home-") do |home|
      ENV["HOME"] = home
      ENV["XDG_CONFIG_HOME"] = File.join(home, ".config")
      ENV["XDG_CACHE_HOME"] = File.join(home, ".cache")
      ENV["XDG_STATE_HOME"] = File.join(home, ".local", "state")
      saved_registry = Souji::Recipe.registry.dup
      Souji::Recipe.reset_registry!
      Souji::Recipes.load_builtins!
      yield
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
end
