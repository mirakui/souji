# frozen_string_literal: true

require "fileutils"
require "souji/recipes/terraform_dir"

RSpec.describe Souji::Recipes::TerraformDir do
  let(:recipe) { described_class.new }

  describe "class-level declarations" do
    it "registers under 'terraform-dir'" do
      expect(described_class.recipe_name).to eq("terraform-dir")
    end

    it "declares no required external commands, so it works after terraform is uninstalled" do
      expect(described_class.required_external_commands).to eq([])
    end

    it "declares only older_than_days" do
      expect(described_class.param_names).to eq([:older_than_days])
    end
  end

  describe "#enumerate" do
    it "proposes one item per .terraform child entry rather than the directory itself" do
      with_tmp_dir do |tmp|
        root = make_terraform_root(File.join(tmp, "infra"), entries: %w[providers modules archive])

        items = recipe.enumerate([tmp], {})

        expect(items.map(&:path)).to eq(
          %w[archive modules providers].map { |e| File.join(root, ".terraform", e) }
        )
        expect(items.map { |i| i.metadata["entry"] }).to eq(%w[archive modules providers])
        expect(items.map(&:recipe).uniq).to eq(["terraform-dir"])
      end
    end

    it "never proposes the entries terraform init does not regenerate" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"), entries: %w[providers],
                                                     workspace: "prd", backend: "s3")

        entries = recipe.enumerate([tmp], {}).map { |i| i.metadata["entry"] }

        expect(entries).to eq(%w[providers])
        expect(entries).not_to include("environment", "terraform.tfstate")
      end
    end

    it "records the workspace and backend so a reviewer can see a production root" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"), workspace: "prd", backend: "s3")

        item = recipe.enumerate([tmp], {}).first

        expect(item.metadata["workspace"]).to eq("prd")
        expect(item.metadata["backend_type"]).to eq("s3")
      end
    end

    it "measures the entry's size" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"))

        expect(recipe.enumerate([tmp], {}).first.size_bytes).to eq(32)
      end
    end

    it "skips a root with no .terraform.lock.hcl, because re-init could change provider versions" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"), lockfile: false)

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "skips a root with no terraform configuration to re-init from" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"), config: false)

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "skips a root whose local backend lock says an operation is in flight" do
      with_tmp_dir do |tmp|
        root = make_terraform_root(File.join(tmp, "infra"))
        File.write(File.join(root, ".terraform.tfstate.lock.info"), "{}")

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "skips a root where a previous apply left errored.tfstate" do
      with_tmp_dir do |tmp|
        root = make_terraform_root(File.join(tmp, "infra"))
        File.write(File.join(root, "errored.tfstate"), "{}")

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "skips a root holding a saved plan, which pins the provider binaries" do
      with_tmp_dir do |tmp|
        root = make_terraform_root(File.join(tmp, "infra"))
        write_saved_plan(root)

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "is not blocked by a human-readable plan dump that merely looks like one" do
      with_tmp_dir do |tmp|
        root = make_terraform_root(File.join(tmp, "infra"))
        File.write(File.join(root, "tfplan.txt"), "Terraform will perform the following actions\n")

        expect(recipe.enumerate([tmp], {}).map { |i| i.metadata["entry"] }).to eq(%w[providers])
      end
    end

    it "stops treating a saved plan as a blocker once it is itself stale" do
      with_tmp_dir do |tmp|
        root = make_terraform_root(File.join(tmp, "infra"))
        plan = write_saved_plan(root)
        backdate(plan, File.join(root, ".terraform", "providers"), days: 120)

        expect(recipe.enumerate([tmp], older_than_days: 90).map { |i| i.metadata["entry"] })
          .to eq(%w[providers])
      end
    end

    it "does not follow a symlinked .terraform" do
      with_tmp_dir do |tmp|
        real = make_terraform_root(File.join(tmp, "real"))
        fake = File.join(tmp, "linked")
        FileUtils.mkdir_p(fake)
        File.write(File.join(fake, "main.tf"), "")
        write_terraform_lockfile(fake)
        File.symlink(File.join(real, ".terraform"), File.join(fake, ".terraform"))

        roots = recipe.enumerate([tmp], {}).map { |i| i.metadata["terraform_root"] }

        expect(roots.uniq).to eq([real])
      end
    end

    describe "with older_than_days:" do
      it "proposes an entry whose last init is old enough" do
        with_tmp_dir do |tmp|
          root = make_terraform_root(File.join(tmp, "infra"))
          backdate(File.join(root, ".terraform", "providers"), days: 200)

          items = recipe.enumerate([tmp], older_than_days: 90)

          expect(items.map { |i| i.metadata["entry"] }).to eq(%w[providers])
          expect(items.first.metadata["older_than_days"]).to eq(90)
          expect(items.first.reason).to match(/last init 200 days ago/)
        end
      end

      it "keeps an entry that was initialized recently" do
        with_tmp_dir do |tmp|
          make_terraform_root(File.join(tmp, "infra"))

          expect(recipe.enumerate([tmp], older_than_days: 90)).to eq([])
        end
      end

      it "gates on the artifact's own generation time, not on project source activity" do
        with_tmp_dir do |tmp|
          # The real-world case this exists for: configuration edited today,
          # provider cache from last year. Gating on source activity would
          # skip exactly the biggest win.
          root = make_terraform_root(File.join(tmp, "infra"))
          backdate(File.join(root, ".terraform", "providers"), days: 300)
          File.write(File.join(root, "main.tf"), "# edited just now\n")

          expect(recipe.enumerate([tmp], older_than_days: 90).map { |i| i.metadata["entry"] })
            .to eq(%w[providers])
        end
      end
    end

    it "prunes the walk rather than descending into .terraform" do
      with_tmp_dir do |tmp|
        root = make_terraform_root(File.join(tmp, "infra"))
        FileUtils.mkdir_p(File.join(root, ".terraform", "providers", "deep", ".terraform"))

        expect(recipe.enumerate([tmp], {}).map { |i| i.metadata["terraform_root"] }.uniq).to eq([root])
      end
    end

    it "returns the same items in the same order across runs" do
      with_tmp_dir do |tmp|
        %w[b a c].each { |name| make_terraform_root(File.join(tmp, name), entries: %w[providers modules]) }

        expect(recipe.enumerate([tmp], {}).map(&:path)).to eq(recipe.enumerate([tmp], {}).map(&:path))
      end
    end
  end

  describe "#verify" do
    def item_for(tmp, **params)
      recipe.enumerate([tmp], params).first
    end

    it "accepts an item whose root is unchanged" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"))

        expect(recipe.verify(item_for(tmp))).to eq(:ok)
      end
    end

    it "skips an entry that is already gone" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"))
        item = item_for(tmp)
        FileUtils.remove_entry(item.path)

        expect(recipe.verify(item)).to eq([:skip, "already removed"])
      end
    end

    it "skips an entry that has since become a symlink" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"))
        item = item_for(tmp)
        FileUtils.remove_entry(item.path)
        File.symlink(tmp, item.path)

        expect(recipe.verify(item)).to eq([:skip, "path is now a symlink"])
      end
    end

    it "refuses a hand-edited plan that names a preserved entry" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"), workspace: "prd")
        item = item_for(tmp)
        tampered = Souji::PlanItem.new(
          id: item.id, recipe: item.recipe,
          path: File.join(File.dirname(item.path), "environment"),
          reason: item.reason, size_bytes: nil,
          metadata: item.metadata.merge("entry" => "environment")
        )

        expect(recipe.verify(tampered)).to eq([:skip, "refusing to delete preserved terraform state"])
      end
    end

    it "skips once the lockfile that made the entry regenerable is gone" do
      with_tmp_dir do |tmp|
        root = make_terraform_root(File.join(tmp, "infra"))
        item = item_for(tmp)
        FileUtils.rm_f(File.join(root, ".terraform.lock.hcl"))

        expect(recipe.verify(item).last).to match(/terraform\.lock\.hcl/)
      end
    end

    it "skips when a terraform operation started between plan and apply" do
      with_tmp_dir do |tmp|
        root = make_terraform_root(File.join(tmp, "infra"))
        item = item_for(tmp)
        File.write(File.join(root, ".terraform.tfstate.lock.info"), "{}")

        expect(recipe.verify(item).last).to match(/in flight/)
      end
    end

    it "skips when the root was re-initialized after planning" do
      with_tmp_dir do |tmp|
        root = make_terraform_root(File.join(tmp, "infra"))
        providers = File.join(root, ".terraform", "providers")
        backdate(providers, days: 200)
        item = item_for(tmp, older_than_days: 90)

        File.utime(Time.now, Time.now, providers)

        expect(recipe.verify(item).last).to match(/initialized 0 days ago/)
      end
    end
  end

  describe "#delete" do
    it "disposes of the entry and reports the outcome" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"))
        item = recipe.enumerate([tmp], {}).first

        expect(%i[trashed deleted]).to include(recipe.delete(item))
      end
    end

    it "reports a failure for a path that is already gone" do
      with_tmp_dir do |tmp|
        make_terraform_root(File.join(tmp, "infra"))
        item = recipe.enumerate([tmp], {}).first
        FileUtils.remove_entry(item.path)

        expect(recipe.delete(item)).to match([:failed, /does not exist/])
      end
    end
  end
end
