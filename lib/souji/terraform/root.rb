# frozen_string_literal: true

require "json"
require_relative "../fs_scan"

module Souji
  module Terraform
    # A directory holding terraform configuration, and everything souji
    # needs to know to judge whether its `.terraform/` is safe to reclaim.
    #
    # The knowledge lives here rather than in the recipe for the same
    # reason `Souji::Git::WorktreePolicy` exists: `souji apply` never reads
    # the scenario again, so `#verify` has to re-apply exactly the rules
    # `#enumerate` applied, and rules that must agree belong in one object.
    #
    # Nothing here raises. A configuration we cannot read is a
    # configuration we refuse to act on, which is the safe direction.
    class Root
      TF_DIR = ".terraform"
      LOCKFILE = ".terraform.lock.hcl"

      # Entries inside `.terraform/` that `terraform init` does NOT
      # regenerate, and which are therefore never deleted:
      #
      # - `environment` records the selected workspace. Losing it silently
      #   reverts you to `default`, so the next apply targets the wrong
      #   workspace. That is the worst failure a disk-cleanup tool could
      #   cause.
      # - `terraform.tfstate` here is the cached *backend configuration*,
      #   not resource state. Re-init usually rebuilds it from the
      #   `backend` block -- but under partial configuration
      #   (`terraform init -backend-config=...`) it is the only on-disk
      #   record of which bucket and key were used, and nothing in the
      #   file says which case you are in. 1.5 KB against an unbounded
      #   recovery cost.
      #
      # Everything else -- `providers/`, `modules/`, `archive/`, and
      # whatever a future terraform release adds -- is regenerable. A
      # denylist rather than an allowlist is what makes that last clause
      # true: an allowlist of {providers, modules} would silently stop
      # reclaiming anything terraform invents next.
      PRESERVED = %w[environment terraform.tfstate].freeze

      STATE_LOCK = ".terraform.tfstate.lock.info"
      ERRORED_STATE = "errored.tfstate"

      # Conventional names for a saved plan. Matching the name is not
      # enough (see #saved_plan): `tfplan.txt`, the human-readable dump,
      # is a common sibling of a real `tfplan` and must not block cleanup
      # forever.
      SAVED_PLAN_RE = /\A(?:tfplan(?:\..+)?|.+\.tfplan|plan\.out|.+\.plan)\z/
      ZIP_MAGIC = "PK\x03\x04".b.freeze

      CONFIG_SUFFIXES = %w[.tf .tf.json].freeze
      PROJECT_MTIME_SUFFIXES = %w[.tf .tf.json .tfvars .tfvars.json].freeze
      PROJECT_MTIME_NAMES = [LOCKFILE, "terraform.tfstate"].freeze

      attr_reader :path

      def initialize(path)
        @path = File.expand_path(path.to_s)
      end

      def terraform_dir
        File.join(@path, TF_DIR)
      end

      def lockfile
        File.join(@path, LOCKFILE)
      end

      def config_file_count
        children(@path).count { |name| config_file?(name) }
      end

      # The `.terraform/` children this recipe may propose, sorted.
      def deletable_entries
        children(terraform_dir)
          .reject { |name| PRESERVED.include?(name) }
          .map { |name| File.join(terraform_dir, name) }
      end

      # Why this root must be left alone, or nil when it may be reclaimed.
      # Re-run verbatim at apply time -- the window between plan and apply
      # is exactly where "someone just started a terraform apply" lives.
      def blocker(older_than_days: nil)
        return "#{TF_DIR}/ is not a directory" unless Souji::FsScan.directory_no_follow?(terraform_dir)
        return "no terraform configuration (*.tf) to re-init from" if config_file_count.zero?
        return "no #{LOCKFILE}, so re-init could silently change provider versions" unless File.file?(lockfile)

        in_flight(older_than_days)
      end

      # When `terraform init` last wrote into `.terraform/`. This, and not
      # project source activity, is what staleness is measured from: the
      # regeneration recipe (the *.tf files plus the lockfile) has already
      # been proven present, so how recently you edited the configuration
      # only predicts when you will pay for a re-init -- it says nothing
      # about whether the cache is still worth keeping.
      def init_at
        Souji::FsScan.newest_mtime([
                                     File.join(terraform_dir, "terraform.tfstate"),
                                     File.join(terraform_dir, "providers"),
                                     File.join(terraform_dir, "modules", "modules.json")
                                   ])
      end

      # Informational only, and deliberately dir-local: recursing into
      # `modules/` would not change any decision.
      def project_at
        Souji::FsScan.newest_mtime(
          children(@path).filter_map { |name| File.join(@path, name) if project_mtime_source?(name) }
        )
      end

      # The selected workspace, from a file we never delete. Recorded so a
      # reviewer can see at a glance that a root is production.
      def workspace
        read_line(File.join(terraform_dir, "environment"))
      end

      def backend_type
        raw = read_file(File.join(terraform_dir, "terraform.tfstate"))
        return nil unless raw

        JSON.parse(raw).dig("backend", "type")
      rescue JSON::ParserError
        nil
      end

      private

      def in_flight(older_than_days)
        return "a terraform operation is in flight (#{STATE_LOCK})" if File.exist?(File.join(@path, STATE_LOCK))
        return "a previous apply left #{ERRORED_STATE} behind" if File.exist?(File.join(@path, ERRORED_STATE))

        plan = saved_plan(older_than_days)
        plan && "a saved plan (#{plan}) still needs these provider binaries"
      end

      # A saved plan pins the exact provider binaries `terraform apply
      # <plan>` will demand, so deleting `.terraform/providers` would
      # invalidate a pending apply. Identified by the zip magic rather
      # than by name, and a plan older than the caller's own staleness
      # threshold does not block: terraform itself refuses a plan whose
      # state has moved on.
      def saved_plan(older_than_days)
        children(@path).find do |name|
          next false unless SAVED_PLAN_RE.match?(name)

          candidate = File.join(@path, name)
          zip?(candidate) && !stale?(candidate, older_than_days)
        end
      end

      def zip?(path)
        File.file?(path) && File.binread(path, 4) == ZIP_MAGIC
      rescue SystemCallError
        false
      end

      def stale?(path, older_than_days)
        return false unless older_than_days

        days = Souji::FsScan.days_since(Souji::FsScan.mtime_or_nil(path))
        !days.nil? && days >= older_than_days
      end

      def config_file?(name)
        CONFIG_SUFFIXES.any? { |suffix| name.end_with?(suffix) } && File.file?(File.join(@path, name))
      end

      def project_mtime_source?(name)
        PROJECT_MTIME_NAMES.include?(name) || PROJECT_MTIME_SUFFIXES.any? { |suffix| name.end_with?(suffix) }
      end

      def children(dir)
        Dir.children(dir).sort
      rescue SystemCallError
        []
      end

      def read_file(path)
        Souji::FsScan.read_text(path)
      end

      def read_line(path)
        read_file(path)&.strip&.then { |text| text.empty? ? nil : text }
      end
    end
  end
end
