# frozen_string_literal: true

require "souji/plan_item"

RSpec.describe Souji::PlanItem do
  let(:valid_attrs) do
    {
      id: "git-worktree:01HZQK2H4Z9YPC7A0F0F4F0F4F",
      recipe: "git-worktree",
      path: "/Users/naruta/work/repo/.git/worktrees/feat-x",
      reason: "Worktree marked prunable by git",
      size_bytes: 248_932,
      metadata: { "branch" => "feat-x", "commit" => "abc1234" }
    }
  end

  describe "construction" do
    it "creates an item with all attributes" do
      item = described_class.new(**valid_attrs)
      expect(item.id).to eq(valid_attrs[:id])
      expect(item.recipe).to eq("git-worktree")
      expect(item.path).to eq(valid_attrs[:path])
      expect(item.reason).to eq(valid_attrs[:reason])
      expect(item.size_bytes).to eq(248_932)
      expect(item.metadata).to eq("branch" => "feat-x", "commit" => "abc1234")
    end

    it "allows size_bytes and metadata to be omitted" do
      attrs = valid_attrs.dup
      attrs.delete(:size_bytes)
      attrs.delete(:metadata)
      item = described_class.new(**attrs)
      expect(item.size_bytes).to be_nil
      expect(item.metadata).to eq({})
    end
  end

  describe "id format validation" do
    it "rejects ids that do not match <recipe>:<ULID>" do
      expect { described_class.new(**valid_attrs, id: "missing-colon") }
        .to raise_error(ArgumentError, /id.*format/i)
    end

    it "rejects ids whose recipe prefix is empty" do
      expect { described_class.new(**valid_attrs, id: ":01HZQK2H4Z9YPC7A0F0F4F0F4F") }
        .to raise_error(ArgumentError, /id.*format/i)
    end

    it "rejects ids whose ULID is the wrong length" do
      expect { described_class.new(**valid_attrs, id: "git-worktree:TOO-SHORT") }
        .to raise_error(ArgumentError, /id.*format/i)
    end
  end

  describe "equality and hash" do
    it "uses value-equality for two items with the same attributes" do
      a = described_class.new(**valid_attrs)
      b = described_class.new(**valid_attrs)
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "distinguishes items that differ in any attribute" do
      a = described_class.new(**valid_attrs)
      b = described_class.new(**valid_attrs, reason: "different reason")
      expect(a).not_to eq(b)
    end
  end

  describe "immutability" do
    it "is frozen on construction" do
      item = described_class.new(**valid_attrs)
      expect(item).to be_frozen
    end
  end

  describe ".generate_id" do
    it "produces a recipe-prefixed identifier with a 26-char ULID" do
      id = described_class.generate_id("git-worktree")
      expect(id).to match(/\Agit-worktree:[0-9A-HJKMNP-TV-Z]{26}\z/)
    end

    it "produces unique ids across calls" do
      ids = Array.new(50) { described_class.generate_id("docker-image") }
      expect(ids.uniq.size).to eq(50)
    end
  end
end
