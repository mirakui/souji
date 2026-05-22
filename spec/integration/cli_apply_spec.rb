# frozen_string_literal: true

require "fileutils"
require "souji/commands/apply_command"
require "souji/commands/plan_command"

RSpec.describe "souji apply (integration)" do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:stdin) { StringIO.new("y\n").tap { |io| def io.tty? = true } }
  let(:plan_command) { Souji::Commands::PlanCommand.new(stdout: StringIO.new, stderr: StringIO.new) }
  let(:apply_command) { Souji::Commands::ApplyCommand.new(stdout: stdout, stderr: stderr, stdin: stdin) }

  around do |example|
    saved = ENV.to_hash
    Dir.mktmpdir("souji-apply-home-") do |home|
      ENV["HOME"] = home
      ENV["XDG_CONFIG_HOME"] = File.join(home, ".config")
      ENV["XDG_CACHE_HOME"] = File.join(home, ".cache")
      ENV["XDG_STATE_HOME"] = File.join(home, ".local", "state")
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

  def generate_plan(name)
    rc = plan_command.call(name)
    raise "plan failed: #{rc}" unless rc.zero?

    File.join(ENV.fetch("XDG_CACHE_HOME"), "souji", "#{name}.soujiplan")
  end

  describe "happy path", :git do
    it "removes prunable worktrees and exits 0" do
      with_tmp_dir do |work|
        repo = build_git_repo(File.join(work, "repo"))
        active = add_worktree(repo: repo, wt_path: File.join(work, "wt-active"), branch_name: "feat-active")
        prunable_one = add_worktree(repo: repo, wt_path: File.join(work, "wt-1"), branch_name: "feat-1")
        prunable_two = add_worktree(repo: repo, wt_path: File.join(work, "wt-2"), branch_name: "feat-2")
        make_worktree_prunable!(prunable_one)
        make_worktree_prunable!(prunable_two)

        install_scenario("weekly", <<~RUBY)
          target "#{work}"
          recipe "git-worktree"
        RUBY
        generate_plan("weekly")

        rc = apply_command.call("weekly", yes: true)
        expect(rc).to eq(0)

        # Active worktree must remain
        expect(Dir.exist?(active)).to be true
        # Prunable worktrees should now be gone from git's bookkeeping
        out = `git -C #{repo} worktree list --porcelain`
        expect(out).not_to include(prunable_one)
        expect(out).not_to include(prunable_two)

        # Action log emitted
        expect(stderr.string).to include("git-worktree")
        expect(stderr.string).to include('"summary":true')
      end
    end
  end

  describe "cancellation" do
    it "returns 130 when the user declines the confirmation prompt", :git do
      with_tmp_dir do |work|
        repo = build_git_repo(File.join(work, "repo"))
        prunable = add_worktree(repo: repo, wt_path: File.join(work, "wt-1"), branch_name: "feat-1")
        make_worktree_prunable!(prunable)

        install_scenario("weekly", <<~RUBY)
          target "#{work}"
          recipe "git-worktree"
        RUBY
        generate_plan("weekly")

        no_stdin = StringIO.new("n\n").tap { |io| def io.tty? = true }
        cmd = Souji::Commands::ApplyCommand.new(stdout: stdout, stderr: stderr, stdin: no_stdin)
        rc = cmd.call("weekly")
        expect(rc).to eq(130)
        # git worktree directory still in git's list
        out = `git -C #{repo} worktree list --porcelain`
        expect(out).to include(prunable)
      end
    end
  end

  describe "--dry-run" do
    it "bypasses confirmation and performs no deletions", :git do
      with_tmp_dir do |work|
        repo = build_git_repo(File.join(work, "repo"))
        prunable = add_worktree(repo: repo, wt_path: File.join(work, "wt-1"), branch_name: "feat-1")
        make_worktree_prunable!(prunable)

        install_scenario("weekly", <<~RUBY)
          target "#{work}"
          recipe "git-worktree"
        RUBY
        plan_path = generate_plan("weekly")
        before_yaml = File.read(plan_path)

        rc = apply_command.call("weekly", dry_run: true)
        expect(rc).to eq(0)
        expect(File.read(plan_path)).to eq(before_yaml)
        out = `git -C #{repo} worktree list --porcelain`
        expect(out).to include(prunable)
      end
    end
  end

  describe "missing plan" do
    it "exits 2 when the bare name does not resolve" do
      rc = apply_command.call("nope")
      expect(rc).to eq(2)
      expected = File.join(ENV.fetch("XDG_CACHE_HOME"), "souji", "nope.soujiplan")
      expect(stderr.string).to include(expected)
    end
  end

  describe "scope-escape in plan" do
    it "exits 66 when an item's path is outside target_roots" do
      with_tmp_dir do |work|
        plan_path = File.join(ENV.fetch("XDG_CACHE_HOME"), "souji", "bad.soujiplan")
        FileUtils.mkdir_p(File.dirname(plan_path))
        File.write(plan_path, <<~YAML)
          souji_plan_version: 1
          souji_version: "0.1.0"
          generated_at: "2026-05-22T13:45:01+09:00"
          scenario: { path: "x", content_sha256: "abc" }
          target_roots: ["#{work}"]
          items:
            - id: "git-worktree:01HZQK2H4Z9YPC7A0F0F4F0F4F"
              recipe: "git-worktree"
              path: "/etc/passwd"
              reason: "scope-escape"
        YAML
        rc = apply_command.call("bad")
        expect(rc).to eq(66)
        expect(stderr.string).to include("/etc/passwd")
      end
    end
  end

  describe "mutually-exclusive log flags" do
    it "exits 2 when both --log-file and --no-log-file are passed" do
      rc = apply_command.call("anything", log_file: "/tmp/x.jsonl", no_log_file: true)
      expect(rc).to eq(2)
      expect(stderr.string).to include("mutually exclusive")
    end
  end
end
