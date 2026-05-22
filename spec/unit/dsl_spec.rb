# frozen_string_literal: true

require "souji/dsl"
require "souji/recipe"

RSpec.describe Souji::DSL::Context do
  let(:context) { described_class.new(scenario_path: "/somewhere/scenario.rb") }

  describe "#target" do
    it "accumulates target roots" do
      context.target("/tmp/a")
      context.target("/tmp/b", "/tmp/c")
      expect(context.target_roots).to eq(["/tmp/a", "/tmp/b", "/tmp/c"])
    end

    it "expands ~ in paths" do
      context.target("~/example")
      expect(context.target_roots.first).to eq(File.expand_path("~/example"))
    end

    it "resolves relative paths against the scenario file's directory" do
      ctx = described_class.new(scenario_path: "/users/x/cleanups/weekly.rb")
      ctx.target("nested-dir")
      expect(ctx.target_roots.first).to eq("/users/x/cleanups/nested-dir")
    end
  end

  describe "#recipe" do
    it "records a recipe invocation with default targets" do
      context.target("/tmp/a")
      context.recipe("git-worktree")
      expect(context.invocations.size).to eq(1)
      inv = context.invocations.first
      expect(inv.name).to eq("git-worktree")
      expect(inv.targets).to eq(["/tmp/a"])
      expect(inv.params).to eq({})
    end

    it "passes keyword params through" do
      context.target("/tmp/a")
      context.recipe("docker-image", older_than_days: 30)
      expect(context.invocations.first.params).to eq(older_than_days: 30)
    end

    it "honors an explicit targets: argument that is a subset of declared targets" do
      context.target("/tmp/a")
      context.target("/tmp/b")
      context.recipe("git-worktree", targets: ["/tmp/a"])
      expect(context.invocations.first.targets).to eq(["/tmp/a"])
    end

    it "raises ScenarioError when targets: escapes declared scope" do
      context.target("/tmp/a")
      expect { context.recipe("git-worktree", targets: ["/tmp/other"]) }
        .to raise_error(Souji::ScenarioError, %r{/tmp/other})
    end
  end

  describe "#with_targets" do
    it "scopes recipe invocations within the block to a narrower target set" do
      context.target("/tmp/a")
      context.target("/tmp/b")
      context.with_targets("/tmp/a") do
        context.recipe("git-worktree")
      end
      context.recipe("docker-image")
      expect(context.invocations[0].targets).to eq(["/tmp/a"])
      expect(context.invocations[1].targets).to eq(["/tmp/a", "/tmp/b"])
    end

    it "raises ScenarioError when block scope escapes declared targets" do
      context.target("/tmp/a")
      expect { context.with_targets("/tmp/elsewhere") { context.recipe("docker-image") } }
        .to raise_error(Souji::ScenarioError, %r{/tmp/elsewhere})
    end
  end

  describe "evaluation of a scenario file" do
    it "evaluates source via instance_eval with filename/line for backtraces" do
      source = <<~RUBY
        target "/tmp/x"
        recipe "git-worktree"
      RUBY
      context.evaluate!(source: source, filename: "/dummy.rb")
      expect(context.target_roots).to eq(["/tmp/x"])
      expect(context.invocations.first.name).to eq("git-worktree")
    end

    it "propagates ScenarioError with the user's filename in the backtrace" do
      source = <<~RUBY
        target "/tmp/x"
        recipe "git-worktree", targets: ["/elsewhere"]
      RUBY
      expect { context.evaluate!(source: source, filename: "/usr/scenario.rb") }
        .to raise_error(Souji::ScenarioError)
    end
  end
end
