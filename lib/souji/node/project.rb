# frozen_string_literal: true

require "json"
require_relative "../fs_scan"

module Souji
  module Node
    # A JavaScript project, and everything souji needs to know to judge
    # whether its `node_modules/` is safe to reclaim.
    #
    # Lives beside the recipe rather than inside it because `souji apply`
    # never reads the scenario again: `#verify` has to re-apply exactly the
    # rules `#enumerate` applied, and rules that must agree belong in one
    # object. Nothing here raises.
    class Project
      MODULES_DIR = "node_modules"
      PACKAGE_JSON = "package.json"

      # Lockfiles in match order; the first one found names the package
      # manager. A lockfile is required, without an escape hatch, because
      # an install without one re-resolves semver ranges: the tree that
      # comes back is not the tree that was deleted, which is a behaviour
      # change dressed up as a cache miss.
      LOCKFILES = {
        "pnpm-lock.yaml" => "pnpm",
        "bun.lock" => "bun",
        "bun.lockb" => "bun",
        "package-lock.json" => "npm",
        "npm-shrinkwrap.json" => "npm",
        "yarn.lock" => "yarn"
      }.freeze

      # Install receipts, in preference order. Each is written by the
      # package manager exactly once per install, which is what makes them
      # a far better staleness signal than `node_modules`' own mtime --
      # anything that touches the directory makes a two-year-old tree look
      # fresh. `.bin` is the fallback every manager rewrites; the
      # directory's own mtime is the last resort, and errs conservatively
      # (a spurious touch makes souji propose *less*).
      RECEIPTS = %w[
        .modules.yaml .pnpm-workspace-state.json .package-lock.json .yarn-integrity .bin
      ].freeze

      attr_reader :path

      def initialize(path)
        @path = File.expand_path(path.to_s)
      end

      def modules_dir
        File.join(@path, MODULES_DIR)
      end

      def package_json
        File.join(@path, PACKAGE_JSON)
      end

      def lockfile
        LOCKFILES.keys.find { |name| File.file?(File.join(@path, name)) }
      end

      def package_manager
        LOCKFILES[lockfile]
      end

      # `package.json`'s own `packageManager` field, when present. Not a
      # safety input -- just the most accurate label to show a human.
      def declared_package_manager
        manifest&.fetch("packageManager", nil)
      end

      # Neither of these disqualifies a project: patch-package re-applies
      # its patches on install and a native build only costs time, so
      # skipping on them would be wrong. They are recorded so a reviewer
      # knows the reinstall will be slow.
      # `scripts` is whatever the file says, not necessarily a Hash, and
      # `dig` raises TypeError on a String or an Array. Nothing between
      # here and PlanCommand rescues that, so one malformed package.json
      # would abort the whole plan for every recipe.
      def postinstall?
        scripts = manifest&.fetch("scripts", nil)
        scripts.is_a?(Hash) && !scripts["postinstall"].nil?
      end

      def patches?
        Souji::FsScan.directory_no_follow?(File.join(@path, "patches"))
      end

      def lockfile_at
        name = lockfile
        name && Souji::FsScan.mtime_or_nil(File.join(@path, name))
      end

      # [signal, time] for the most recent install, or nil.
      def install
        found = RECEIPTS.filter_map do |name|
          at = Souji::FsScan.mtime_or_nil(File.join(modules_dir, name))
          [name, at] if at
        end
        return found.max_by(&:last) unless found.empty?

        at = Souji::FsScan.mtime_or_nil(modules_dir)
        at && [MODULES_DIR, at]
      end

      # Why this project's node_modules must be left alone, or nil.
      #
      # Requiring a sibling `package.json` is what makes a pnpm workspace
      # root whose packages live elsewhere -- lockfile present, manifest
      # absent -- correctly untouchable. Requiring a sibling lockfile is
      # also what makes a monorepo compose for free: a package-level
      # `services/api/node_modules` has no lockfile of its own, so only the
      # workspace root is ever proposed.
      def blocker
        return "#{MODULES_DIR}/ is not a directory" unless Souji::FsScan.directory_no_follow?(modules_dir)
        return "no #{PACKAGE_JSON} to reinstall from" unless File.file?(package_json)
        return "#{PACKAGE_JSON} does not parse, so the reinstall is not reproducible" if manifest.nil?
        return "no lockfile, so a reinstall would re-resolve semver ranges" unless lockfile

        nil
      end

      private

      def manifest
        return @manifest if defined?(@manifest)

        @manifest = parse_manifest
      end

      def parse_manifest
        raw = Souji::FsScan.read_text(package_json)
        return nil unless raw

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end
