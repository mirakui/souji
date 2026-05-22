# frozen_string_literal: true

require "souji/recipes/git_worktree"

RSpec.describe Souji::Recipes::GitWorktree, :git do
  let(:recipe) { described_class.new }

  describe "class-level declarations" do
    it "registers under 'git-worktree'" do
      expect(described_class.recipe_name).to eq("git-worktree")
    end

    it "requires the git external command" do
      expect(described_class.required_external_commands).to eq(["git"])
    end
  end

  describe "#enumerate" do
    it "returns no items for a repo with only the primary worktree" do
      with_tmp_dir do |dir|
        build_git_repo(File.join(dir, "repo"))
        items = recipe.enumerate([dir], {})
        expect(items).to eq([])
      end
    end

    it "returns prunable worktrees as plan items, omitting active ones" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        active = add_worktree(repo: repo, wt_path: File.join(dir, "wt-active"), branch_name: "feat-active")
        prunable_one = add_worktree(repo: repo, wt_path: File.join(dir, "wt-1"), branch_name: "feat-1")
        prunable_two = add_worktree(repo: repo, wt_path: File.join(dir, "wt-2"), branch_name: "feat-2")
        make_worktree_prunable!(prunable_one)
        make_worktree_prunable!(prunable_two)

        items = recipe.enumerate([dir], {})

        paths = items.map(&:path)
        expect(paths).to include(prunable_one, prunable_two)
        expect(paths).not_to include(active)
        items.each do |item|
          expect(item.recipe).to eq("git-worktree")
          expect(item.id).to match(/\Agit-worktree:[0-9A-HJKMNP-TV-Z]{26}\z/)
          expect(item.reason).to match(/prunable/i)
        end
      end
    end

    it "returns items in deterministic order across re-runs" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        %w[a b c].each do |name|
          path = add_worktree(repo: repo, wt_path: File.join(dir, "wt-#{name}"), branch_name: "feat-#{name}")
          make_worktree_prunable!(path)
        end
        run1 = recipe.enumerate([dir], {}).map(&:path)
        run2 = recipe.enumerate([dir], {}).map(&:path)
        expect(run1).to eq(run2)
      end
    end

    it "does not modify the filesystem under target_roots" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        active = add_worktree(repo: repo, wt_path: File.join(dir, "wt-active"), branch_name: "feat-active")
        before = Digest::SHA256.file(File.join(active, "README")).hexdigest

        recipe.enumerate([dir], {})

        after = Digest::SHA256.file(File.join(active, "README")).hexdigest
        expect(after).to eq(before)
      end
    end
  end
end
