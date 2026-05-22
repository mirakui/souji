# frozen_string_literal: true

require "souji/recipe"

RSpec.describe Souji::Recipe do
  # Save and restore the global registry around each example so subclass
  # registrations from one test don't leak into the next.
  around do |example|
    saved = described_class.registry.dup
    described_class.reset_registry!
    example.run
  ensure
    described_class.reset_registry!
    saved.each { |name, klass| described_class.register(name, klass) }
  end

  describe ".recipe_name validation" do
    it "accepts valid names matching /[a-z][a-z0-9-]*/" do
      expect do
        Class.new(described_class) do
          recipe_name "git-worktree"
        end
      end.not_to raise_error
    end

    it "rejects names with uppercase letters" do
      expect do
        Class.new(described_class) do
          recipe_name "Bad-Name"
        end
      end.to raise_error(ArgumentError, /recipe_name/)
    end

    it "rejects names starting with a digit" do
      expect do
        Class.new(described_class) do
          recipe_name "1-bad"
        end
      end.to raise_error(ArgumentError, /recipe_name/)
    end

    it "rejects empty names" do
      expect do
        Class.new(described_class) do
          recipe_name ""
        end
      end.to raise_error(ArgumentError, /recipe_name/)
    end
  end

  describe ".required_external_commands" do
    it "defaults to an empty array" do
      klass = Class.new(described_class) do
        recipe_name "no-deps"
      end
      expect(klass.required_external_commands).to eq([])
    end

    it "records the declared commands" do
      klass = Class.new(described_class) do
        recipe_name "with-deps"
        required_external_commands "git", "docker"
      end
      expect(klass.required_external_commands).to eq(%w[git docker])
    end
  end

  describe ".description" do
    it "stores a one-line description" do
      klass = Class.new(described_class) do
        recipe_name "described"
        description "Clean stale things"
      end
      expect(klass.description).to eq("Clean stale things")
    end

    it "returns nil when no description was declared" do
      klass = Class.new(described_class) do
        recipe_name "undescribed"
      end
      expect(klass.description).to be_nil
    end
  end

  describe "registry" do
    it "registers a subclass under its recipe_name" do
      klass = Class.new(described_class) do
        recipe_name "alpha"
      end
      expect(described_class.registry).to include("alpha" => klass)
    end

    it "raises DuplicateRecipeError when two classes declare the same name" do
      Class.new(described_class) { recipe_name "dup" }
      expect do
        Class.new(described_class) { recipe_name "dup" }
      end.to raise_error(Souji::DuplicateRecipeError, /dup/)
    end

    it "looks up a recipe by name" do
      klass = Class.new(described_class) { recipe_name "lookup-target" }
      expect(described_class.fetch("lookup-target")).to eq(klass)
    end

    it "raises UnknownRecipeError on unknown lookup" do
      expect { described_class.fetch("not-registered") }
        .to raise_error(Souji::UnknownRecipeError, /not-registered/)
    end
  end

  describe ".available?" do
    it "returns true for a command that exists" do
      expect(described_class.available?("sh")).to be true
    end

    it "returns false for a command that does not exist" do
      expect(described_class.available?("definitely-not-a-real-binary-12345")).to be false
    end

    it "escapes shell metacharacters in the probe" do
      expect(described_class.available?("foo; rm -rf /")).to be false
    end
  end

  describe "lifecycle method stubs (abstract)" do
    let(:klass) { Class.new(described_class) { recipe_name "stub" } }

    it "raises NotImplementedError from #enumerate" do
      expect { klass.new.enumerate(["/tmp"], {}) }.to raise_error(NotImplementedError)
    end

    it "raises NotImplementedError from #verify" do
      expect { klass.new.verify(double) }.to raise_error(NotImplementedError)
    end

    it "raises NotImplementedError from #delete" do
      expect { klass.new.delete(double) }.to raise_error(NotImplementedError)
    end
  end
end
