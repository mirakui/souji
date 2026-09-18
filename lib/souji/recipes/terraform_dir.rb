# frozen_string_literal: true

require "time"
require_relative "../recipe"
require_relative "../plan_item"
require_relative "../trash"
require_relative "../fs_scan"
require_relative "../terraform/root"

module Souji
  module Recipes
    # Reclaims the regenerable contents of the `.terraform/` directories
    # that accumulate under a workstation's terraform roots. On a machine
    # with a few dozen live stacks this is routinely the single largest
    # pile of pure cache on disk, and `terraform init` rebuilds all of it.
    #
    # The unit of deletion is a *child entry* of `.terraform/`, never the
    # directory itself. Two of its children are not regenerable, and
    # choosing a deletion unit that cannot include them dissolves the
    # hazard rather than guarding against it -- see
    # `Souji::Terraform::Root::PRESERVED` for which and why. The cost is a
    # few more plan items and an empty `.terraform/` husk left behind;
    # both are cheap next to targeting the wrong workspace.
    #
    # Complementary to, and independent of, `terraform-provider`: that
    # recipe prunes the *shared* plugin cache using the `.terraform.lock.hcl`
    # files as its reference set, and this recipe never deletes a lockfile
    # (it requires one, and the denylist preserves nothing else it would
    # need). So there is no ordering dependency between the two, in either
    # direction, within a run or across runs.
    class TerraformDir < Souji::Recipe
      recipe_name "terraform-dir"
      description "Remove the regenerable contents of local .terraform/ directories (terraform init rebuilds them)"
      param :older_than_days,
            "Only propose contents whose last `terraform init` is at least this many days old " \
            "(default: no age filter)"

      # The walk has to be let into `.terraform` to find it; it prunes on
      # arrival, because `.terraform/providers/**/<os_arch>` is six levels
      # deep with a 700 MB binary at the bottom.
      WALK_SKIP_DIRS = (Souji::FsScan::SKIP_DIR_NAMES - [Souji::Terraform::Root::TF_DIR]).freeze

      def enumerate(target_roots, params)
        older_than_days = params[:older_than_days]
        target_roots.flat_map { |target| scan(target, older_than_days) }
      end

      def verify(plan_item)
        metadata = plan_item.metadata
        return [:skip, "already removed"] unless File.exist?(plan_item.path)
        return [:skip, "path is now a symlink"] if File.symlink?(plan_item.path)
        if Souji::Terraform::Root::PRESERVED.include?(metadata["entry"])
          return [:skip, "refusing to delete preserved terraform state"]
        end

        recheck(Souji::Terraform::Root.new(metadata["terraform_root"]), metadata["older_than_days"])
      end

      def delete(plan_item)
        Souji::Trash.dispose(plan_item.path)
      rescue StandardError => e
        [:failed, e.message]
      end

      private

      def scan(target, older_than_days)
        items = []
        Souji::FsScan.walk_dirs(target, skip: WALK_SKIP_DIRS) do |dir|
          next unless File.basename(dir) == Souji::Terraform::Root::TF_DIR

          items.concat(assess(File.dirname(dir), older_than_days))
          :prune
        end
        items
      end

      def assess(path, older_than_days)
        progress.scanning(path)
        root = Souji::Terraform::Root.new(path)
        reason = recheck(root, older_than_days)
        unless reason == :ok
          progress.note("keeping #{path}/#{Souji::Terraform::Root::TF_DIR}: #{reason.last}")
          return []
        end

        build_items(root, older_than_days)
      end

      # The single judgement, shared by plan and apply so the two cannot
      # drift: is this root's `.terraform/` safe to reclaim right now?
      def recheck(root, older_than_days)
        blocker = root.blocker(older_than_days: older_than_days)
        return [:skip, blocker] if blocker

        age_skip(root, older_than_days) || :ok
      end

      def age_skip(root, older_than_days)
        case (verdict = Souji::FsScan.staleness(root.init_at, older_than_days))
        when :stale then nil
        when :unknown then [:skip, "cannot tell when it was last initialized"]
        else [:skip, "initialized #{Souji::FsScan.days_phrase(verdict.last)} ago"]
        end
      end

      def build_items(root, older_than_days)
        init_at = root.init_at
        shared = shared_metadata(root, init_at, older_than_days)
        root.deletable_entries.map do |entry|
          Souji::PlanItem.new(
            id: Souji::PlanItem.generate_id("terraform-dir"),
            recipe: "terraform-dir",
            path: entry,
            reason: reason_for(entry, init_at),
            size_bytes: Souji::FsScan.dir_size(entry),
            metadata: shared.merge("entry" => File.basename(entry))
          )
        end
      end

      def shared_metadata(root, init_at, older_than_days)
        {
          "terraform_root" => root.path,
          "lockfile" => root.lockfile,
          "tf_file_count" => root.config_file_count,
          "init_at" => iso8601(init_at),
          "older_than_days" => older_than_days,
          "project_at" => iso8601(root.project_at),
          "workspace" => root.workspace,
          "backend_type" => root.backend_type
        }.compact
      end

      def reason_for(entry, init_at)
        days = Souji::FsScan.days_since(init_at)
        age = days ? "last init #{Souji::FsScan.days_phrase(days)} ago" : "last init unknown"
        "#{File.basename(entry)}/ is regenerable by `terraform init` (#{age}); " \
          "provider versions stay pinned by .terraform.lock.hcl"
      end

      def iso8601(time)
        time&.utc&.iso8601
      end
    end
  end
end
