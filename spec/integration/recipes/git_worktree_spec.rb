# frozen_string_literal: true

require "stringio"
require "souji/recipes/git_worktree"

RSpec.describe Souji::Recipes::GitWorktree, :git do
  let(:recipe) { described_class.new }

  # A repo whose `main` is pushed to a local bare origin, with one linked
  # worktree on `feat` carrying its own commit. Returns [repo, worktree].
  def build_repo_with_feature_worktree(dir)
    repo = build_git_repo(File.join(dir, "repo"))
    add_remote_with_main(repo: repo)
    wt = add_worktree(repo: repo, wt_path: File.join(dir, "wt-feat"), branch_name: "feat")
    commit_in_worktree(wt)
    [repo, wt]
  end

  # The single merged plan item `enumerate` proposes for `dir`.
  def merged_item_for(dir, params = { merged: true })
    items = recipe.enumerate([dir], params)
    expect(items.size).to eq(1)
    items.first
  end

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

    # A repo inside the targets may register worktrees anywhere on disk.
    # Those registrations are out of scope for this scenario, so the recipe
    # must not propose them (Souji::Plan's containment check is the last
    # safety net, not the mechanism users are expected to hit).
    it "omits prunable worktrees registered outside the target roots" do
      with_tmp_dir do |dir|
        scope = File.join(dir, "scope")
        repo = build_git_repo(File.join(scope, "repo"))
        inside = add_worktree(repo: repo, wt_path: File.join(scope, "wt-in"), branch_name: "feat-in")
        outside = add_worktree(repo: repo, wt_path: File.join(dir, "outside", "wt-out"), branch_name: "feat-out")
        make_worktree_prunable!(inside)
        make_worktree_prunable!(outside)

        paths = recipe.enumerate([scope], {}).map(&:path)

        expect(paths).to include(inside)
        expect(paths).not_to include(outside)
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

    it "never proposes a locked worktree" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        locked = add_worktree(repo: repo, wt_path: File.join(dir, "wt-locked"), branch_name: "feat-locked")
        lock_worktree!(repo: repo, wt_path: locked)
        make_worktree_prunable!(locked)

        paths = recipe.enumerate([dir], {}).map(&:path)

        expect(paths).not_to include(locked)
      end
    end
  end

  describe "#enumerate with merged detection" do
    it "ignores merged worktrees unless merged detection is requested" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")

        expect(recipe.enumerate([dir], {})).to eq([])
        expect(recipe.enumerate([dir], { merged: false }).map(&:path)).not_to include(wt)
      end
    end

    it "proposes a worktree whose branch is merged into the default branch" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")

        items = recipe.enumerate([dir], { merged: true })

        expect(items.map(&:path)).to eq([wt])
        item = items.first
        expect(item.reason).to match(%r{merged into origin/main})
        expect(item.metadata["detection"]).to eq("merged")
        expect(item.metadata["merged_into"]).to eq("origin/main")
        expect(item.metadata["branch"]).to eq("feat")
        expect(item.size_bytes).to be > 0
      end
    end

    it "leaves an unmerged worktree alone" do
      with_tmp_dir do |dir|
        _repo, wt = build_repo_with_feature_worktree(dir)

        paths = recipe.enumerate([dir], { merged: true }).map(&:path)

        expect(paths).not_to include(wt)
      end
    end

    # The main worktree sits on the very branch we compare against, so it
    # is trivially "merged". Excluding it is what keeps merged detection
    # from proposing the repository itself.
    it "never proposes the repository's own main worktree" do
      with_tmp_dir do |dir|
        repo, = build_repo_with_feature_worktree(dir)

        paths = recipe.enumerate([dir], { merged: true }).map(&:path)

        expect(paths).not_to include(repo)
      end
    end

    it "skips a merged worktree with uncommitted changes to tracked files" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")
        dirty_worktree!(wt)

        paths = recipe.enumerate([dir], { merged: true }).map(&:path)

        expect(paths).not_to include(wt)
      end
    end

    it "still proposes a merged worktree that only carries untracked files" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")
        add_untracked_file!(wt)

        paths = recipe.enumerate([dir], { merged: true }).map(&:path)

        expect(paths).to include(wt)
      end
    end

    it "never proposes a locked worktree even when it is merged" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")
        lock_worktree!(repo: repo, wt_path: wt)

        paths = recipe.enumerate([dir], { merged: true }).map(&:path)

        expect(paths).not_to include(wt)
      end
    end

    it "falls back to origin/main when refs/remotes/origin/HEAD is absent" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")
        sh!("git", "-C", repo, "remote", "set-head", "origin", "--delete")

        paths = recipe.enumerate([dir], { merged: true }).map(&:path)

        expect(paths).to eq([wt])
      end
    end

    it "compares against merged_into: instead of the auto-detected base" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        # `feat` is merged into main, but not into the release line, so a
        # scenario pinned to origin/release must not propose it.
        sh!("git", "-C", repo, "push", "-q", "origin", "main:release")
        merge_branch_into_default!(repo: repo, branch: "feat")
        sh!("git", "-C", repo, "fetch", "-q", "origin")

        expect(recipe.enumerate([dir], { merged: true }).map(&:path)).to eq([wt])
        expect(recipe.enumerate([dir], { merged: true, merged_into: "origin/release" }).map(&:path)).to eq([])
      end
    end

    it "keeps finding prunable worktrees in a repo with no resolvable base ref" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        gone = add_worktree(repo: repo, wt_path: File.join(dir, "wt-gone"), branch_name: "feat-gone")
        make_worktree_prunable!(gone)

        items = recipe.enumerate([dir], { merged: true })

        expect(items.map(&:path)).to eq([gone])
        expect(items.first.metadata["detection"]).to eq("prunable")
      end
    end

    it "reports on stderr why a repository got no merged check" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        add_worktree(repo: repo, wt_path: File.join(dir, "wt-feat"), branch_name: "feat")
        io = StringIO.new
        recipe.progress = Souji::Progress.new(io: io)

        recipe.enumerate([dir], { merged: true })

        expect(io.string).to include("#{repo}: no base ref to compare against")
      end
    end
  end

  describe "#enumerate with fetch:" do
    # Merge `feat` into main and push it, then rewind the local
    # remote-tracking ref so this clone still believes `feat` is unmerged.
    def merge_upstream_behind_our_back(repo:, branch: "feat")
      stale = sha_of(repo: repo, rev: "refs/remotes/origin/main")
      merge_branch_into_default!(repo: repo, branch: branch)
      stale_tracking_ref!(repo: repo, commit: stale)
    end

    it "misses an upstream merge when fetch is off" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_upstream_behind_our_back(repo: repo)

        expect(recipe.enumerate([dir], { merged: true }).map(&:path)).not_to include(wt)
      end
    end

    it "sees an upstream merge when fetch is on" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_upstream_behind_our_back(repo: repo)

        expect(recipe.enumerate([dir], { merged: true, fetch: true }).map(&:path)).to eq([wt])
      end
    end

    # An unreachable remote must not abort the run or hang it on a prompt;
    # the cached ref is still a usable answer.
    it "falls back to the cached ref when the fetch fails" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")
        sh!("git", "-C", repo, "remote", "set-url", "origin", File.join(dir, "no-such-remote.git"))
        io = StringIO.new
        recipe.progress = Souji::Progress.new(io: io)

        expect(recipe.enumerate([dir], { merged: true, fetch: true }).map(&:path)).to eq([wt])
        expect(io.string).to include("fetch failed, judging against the cached origin/main")
      end
    end
  end

  describe "#enumerate with older_than_days:" do
    # A worktree on branch `old` whose only commit is `age_days` old.
    def build_repo_with_stale_worktree(dir, age_days: 120)
      repo = build_git_repo(File.join(dir, "repo"))
      wt = add_worktree(repo: repo, wt_path: File.join(dir, "wt-old"), branch_name: "old")
      commit_in_worktree(wt, days_ago: age_days)
      [repo, wt]
    end

    it "ignores commit age unless older_than_days is given" do
      with_tmp_dir do |dir|
        build_repo_with_stale_worktree(dir)

        expect(recipe.enumerate([dir], {})).to eq([])
      end
    end

    it "proposes a worktree whose last commit predates the threshold" do
      with_tmp_dir do |dir|
        _repo, wt = build_repo_with_stale_worktree(dir, age_days: 120)

        items = recipe.enumerate([dir], { older_than_days: 30 })

        expect(items.map(&:path)).to eq([wt])
        item = items.first
        expect(item.reason).to match(/Branch old last committed 1\d\d days ago/)
        expect(item.metadata["detection"]).to eq("stale")
        expect(item.metadata["older_than_days"]).to eq(30)
        expect(item.metadata["last_commit_at"]).to match(/\A\d{4}-\d\d-\d\dT/)
        expect(item.size_bytes).to be > 0
      end
    end

    it "leaves a worktree committed to inside the threshold alone" do
      with_tmp_dir do |dir|
        _repo, wt = build_repo_with_stale_worktree(dir, age_days: 5)

        expect(recipe.enumerate([dir], { older_than_days: 30 }).map(&:path)).not_to include(wt)
      end
    end

    it "skips a stale worktree with uncommitted changes to tracked files" do
      with_tmp_dir do |dir|
        _repo, wt = build_repo_with_stale_worktree(dir)
        dirty_worktree!(wt)

        expect(recipe.enumerate([dir], { older_than_days: 30 }).map(&:path)).not_to include(wt)
      end
    end

    it "never proposes a locked worktree however stale it is" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_stale_worktree(dir)
        lock_worktree!(repo: repo, wt_path: wt)

        expect(recipe.enumerate([dir], { older_than_days: 30 }).map(&:path)).not_to include(wt)
      end
    end

    # Deleting a worktree leaves its branch behind, so the commits survive.
    # A detached HEAD has no such anchor: if nothing else points at the
    # commit, removing the worktree makes it gc fodder.
    it "refuses a stale detached worktree no ref points at" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        wt = add_detached_worktree(repo: repo, wt_path: File.join(dir, "wt-det"))
        commit_in_worktree(wt, days_ago: 120)
        io = StringIO.new
        recipe.progress = Souji::Progress.new(io: io)

        expect(recipe.enumerate([dir], { older_than_days: 30 })).to eq([])
        expect(io.string).to include("#{wt}: detached HEAD is not reachable from any ref")
      end
    end

    it "accepts a stale detached worktree that some ref still contains" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        sh!("git", "-C", repo, "checkout", "-q", "-b", "old")
        commit_in_worktree(repo, message: "old work", file: "OLD", days_ago: 120)
        sh!("git", "-C", repo, "checkout", "-q", "main")
        wt = add_detached_worktree(repo: repo, wt_path: File.join(dir, "wt-det"), commit: "old")

        expect(recipe.enumerate([dir], { older_than_days: 30 }).map(&:path)).to eq([wt])
      end
    end

    # merged: and older_than_days: are independent reasons to propose a
    # worktree, so a run with both on returns the union.
    it "labels each worktree by the rule that caught it" do
      with_tmp_dir do |dir|
        repo, merged = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")
        stale = add_worktree(repo: repo, wt_path: File.join(dir, "wt-old"), branch_name: "old")
        commit_in_worktree(stale, days_ago: 120)

        items = recipe.enumerate([dir], { merged: true, older_than_days: 30 })

        expect(items.map { |i| [i.path, i.metadata["detection"]] })
          .to contain_exactly([merged, "merged"], [stale, "stale"])
      end
    end
  end

  describe "#verify" do
    it "accepts a merged worktree that has not changed since planning" do
      with_tmp_dir do |dir|
        repo, = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")

        expect(recipe.verify(merged_item_for(dir))).to eq(:ok)
      end
    end

    it "skips a merged worktree that has been dirtied since planning" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")
        item = merged_item_for(dir)
        dirty_worktree!(wt)

        expect(recipe.verify(item)).to eq([:skip, "worktree has uncommitted changes"])
      end
    end

    it "skips a merged worktree whose branch has moved on since planning" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")
        item = merged_item_for(dir)
        commit_in_worktree(wt, message: "resumed", file: "MORE")

        expect(recipe.verify(item)).to eq([:skip, "worktree is no longer merged into origin/main"])
      end
    end

    it "skips a merged worktree that has been locked since planning" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")
        item = merged_item_for(dir)
        lock_worktree!(repo: repo, wt_path: wt)

        expect(recipe.verify(item)).to eq([:skip, "worktree is locked"])
      end
    end

    # The documented recovery from a vanished worktree is `git worktree
    # prune` followed by `git worktree add` at the same path. An apply that
    # runs after that must not touch the fresh checkout.
    it "accepts a stale worktree nobody has touched since planning" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        wt = add_worktree(repo: repo, wt_path: File.join(dir, "wt-old"), branch_name: "old")
        commit_in_worktree(wt, days_ago: 120)

        expect(recipe.verify(merged_item_for(dir, { older_than_days: 30 }))).to eq(:ok)
      end
    end

    it "skips a stale worktree that has been committed to since planning" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        wt = add_worktree(repo: repo, wt_path: File.join(dir, "wt-old"), branch_name: "old")
        commit_in_worktree(wt, days_ago: 120)
        item = merged_item_for(dir, { older_than_days: 30 })
        commit_in_worktree(wt, message: "resumed", file: "MORE")

        expect(recipe.verify(item)).to eq([:skip, "worktree has a commit newer than 30 days"])
      end
    end

    it "skips a prunable worktree that has been re-created since planning" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        wt = add_worktree(repo: repo, wt_path: File.join(dir, "wt-gone"), branch_name: "feat-gone")
        make_worktree_prunable!(wt)
        item = recipe.enumerate([dir], {}).first
        sh!("git", "-C", repo, "worktree", "prune")
        sh!("git", "-C", repo, "worktree", "add", "-q", wt, "feat-gone")

        expect(recipe.verify(item)).to eq([:skip, "worktree is no longer prunable"])
      end
    end

    it "skips a worktree whose registration is already gone" do
      with_tmp_dir do |dir|
        repo = build_git_repo(File.join(dir, "repo"))
        wt = add_worktree(repo: repo, wt_path: File.join(dir, "wt-gone"), branch_name: "feat-gone")
        make_worktree_prunable!(wt)
        item = recipe.enumerate([dir], {}).first
        sh!("git", "-C", repo, "worktree", "prune")

        expect(recipe.verify(item)).to eq([:skip, "worktree no longer registered with git"])
      end
    end
  end

  describe "#delete" do
    it "disposes of a merged worktree and leaves no registration behind" do
      with_tmp_dir do |dir|
        repo, wt = build_repo_with_feature_worktree(dir)
        merge_branch_into_default!(repo: repo, branch: "feat")
        item = merged_item_for(dir)

        outcome = recipe.delete(item)

        expect(outcome).to eq(:trashed).or eq(:deleted)
        expect(Dir.exist?(wt)).to be false
        expect(Souji::Git::WorktreeList.for(repo).linked).to be_empty
      end
    end
  end
end
