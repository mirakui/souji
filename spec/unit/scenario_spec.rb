# frozen_string_literal: true

require "souji/scenario"
require "souji/recipes"

RSpec.describe Souji::Scenario do
  def write_scenario(dir, name, body)
    path = File.join(dir, "#{name}.rb")
    File.write(path, body)
    path
  end

  describe ".from_file" do
    it "loads a scenario file and records targets + invocations" do
      with_tmp_dir do |dir|
        path = write_scenario(dir, "weekly", <<~RUBY)
          target "#{dir}/work"
          recipe "git-worktree"
        RUBY
        scenario = described_class.from_file(path)
        expect(scenario.target_roots).to eq([File.join(dir, "work")])
        expect(scenario.invocations.map(&:name)).to eq(["git-worktree"])
        expect(scenario.path).to eq(path)
        expect(scenario.content_sha256).to match(/\A[0-9a-f]{64}\z/)
      end
    end

    it "raises Souji::ScenarioError on syntax errors" do
      with_tmp_dir do |dir|
        path = write_scenario(dir, "broken", "target 'x'\nrecipe 'git-worktree' do |x|\n")
        expect { described_class.from_file(path) }
          .to raise_error(Souji::ScenarioError, /broken/)
      end
    end

    it "passes the scenario filename to instance_eval for tracebacks" do
      with_tmp_dir do |dir|
        path = write_scenario(dir, "boom", "raise 'on line 1'\n")
        begin
          described_class.from_file(path)
          raise "should not reach"
        rescue Souji::ScenarioError => e
          expect(e.message).to include(path)
        end
      end
    end
  end

  describe "#run_plan" do
    let(:fake_recipe_class) do
      Class.new(Souji::Recipe) do
        recipe_name "fake-recipe"

        def enumerate(target_roots, _params)
          target_roots.map do |root|
            Souji::PlanItem.new(
              id: Souji::PlanItem.generate_id("fake-recipe"),
              recipe: "fake-recipe",
              path: File.join(root, "file"),
              reason: "stub",
              size_bytes: 1
            )
          end
        end
      end
    end

    around do |example|
      saved = Souji::Recipe.registry.dup
      Souji::Recipe.reset_registry!
      fake_recipe_class
      example.run
    ensure
      Souji::Recipe.reset_registry!
      saved.each { |n, k| Souji::Recipe.register(n, k) }
    end

    it "produces a Souji::Plan with items from each invocation" do
      with_tmp_dir do |dir|
        path = write_scenario(dir, "fake", <<~RUBY)
          target "#{dir}"
          recipe "fake-recipe"
        RUBY
        scenario = described_class.from_file(path)
        plan = scenario.run_plan
        expect(plan).to be_a(Souji::Plan)
        expect(plan.items.size).to eq(1)
        expect(plan.items.first.recipe).to eq("fake-recipe")
        expect(plan.target_roots).to eq([dir])
      end
    end

    it "raises Souji::UnknownRecipeError when invocation references unknown recipe" do
      with_tmp_dir do |dir|
        path = write_scenario(dir, "unknown", <<~RUBY)
          target "#{dir}"
          recipe "no-such-recipe"
        RUBY
        scenario = described_class.from_file(path)
        expect { scenario.run_plan }.to raise_error(Souji::UnknownRecipeError, /no-such-recipe/)
      end
    end

    it "skips recipes whose required external command is missing and warns on stderr" do
      Souji::Recipe.reset_registry!
      Class.new(Souji::Recipe) do
        recipe_name "needs-missing-cmd"
        required_external_commands "definitely-not-a-real-binary-12345"
        def enumerate(_t, _p) = (raise "should not be called")
      end
      Class.new(Souji::Recipe) do
        recipe_name "always-works"
        def enumerate(target_roots, _p)
          [Souji::PlanItem.new(
            id: Souji::PlanItem.generate_id("always-works"),
            recipe: "always-works",
            path: File.join(target_roots.first, "x"),
            reason: "ok"
          )]
        end
      end

      with_tmp_dir do |dir|
        path = write_scenario(dir, "mixed", <<~RUBY)
          target "#{dir}"
          recipe "needs-missing-cmd"
          recipe "always-works"
        RUBY
        scenario = described_class.from_file(path)
        plan = nil
        $stderr = StringIO.new
        begin
          plan = scenario.run_plan
        ensure
          captured_err = $stderr.string
          $stderr = STDERR
        end
        expect(captured_err).to include("needs-missing-cmd")
        expect(captured_err).to include("definitely-not-a-real-binary-12345")
        expect(plan.items.size).to eq(1)
        expect(plan.items.first.recipe).to eq("always-works")
      end
    end
  end
end
