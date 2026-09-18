# frozen_string_literal: true

require "time"
require_relative "../recipe"
require_relative "../plan_item"
require_relative "../trash"
require_relative "../fs_scan"
require_relative "../python/venv"

module Souji
  module Recipes
    # Reclaims Python virtualenvs a sibling manifest can recreate.
    #
    # Detection is structural rather than name-based, and the manifest
    # must sit in the venv's immediate parent -- see `Souji::Python::Venv`
    # for both rules and their reasoning.
    #
    # Known limitation, deliberately not special-cased: a venv whose
    # parent is not the project directory has no sibling manifest and is
    # therefore never proposed. That covers Pipenv's default location
    # (`~/.local/share/virtualenvs/<proj>-<hash>`) and direnv's
    # `.direnv/python-<version>/`. `PIPENV_VENV_IN_PROJECT=1` brings the
    # Pipenv case into scope; the direnv case stays out, because the venv
    # there is direnv's to recreate, not ours.
    class PythonVenv < Souji::Recipe
      recipe_name "python-venv"
      description "Remove stale Python virtualenvs that a sibling manifest can recreate"
      param :older_than_days,
            "Only propose venvs whose last install is at least this many days old " \
            "(default: no age filter)"

      # A venv is found by entering it, so the walk is let into the
      # conventional names; it prunes on arrival either way.
      WALK_SKIP_DIRS = (Souji::FsScan::SKIP_DIR_NAMES - %w[.venv venv]).freeze

      def enumerate(target_roots, params)
        older_than_days = params[:older_than_days]
        target_roots.flat_map { |target| scan(target, older_than_days) }
      end

      def verify(plan_item)
        return [:skip, "already removed"] unless Dir.exist?(plan_item.path)
        return [:skip, "path is now a symlink"] if File.symlink?(plan_item.path)

        recheck(Souji::Python::Venv.new(plan_item.path), plan_item.metadata["older_than_days"])
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
          venv = Souji::Python::Venv.new(dir)
          next unless venv.venv?

          progress.scanning(dir)
          item = assess(venv, older_than_days)
          items << item if item
          :prune
        end
        items
      end

      def assess(venv, older_than_days)
        reason = recheck(venv, older_than_days)
        return build_item(venv, older_than_days) if reason == :ok

        progress.note("keeping #{venv.path}: #{reason.last}")
        nil
      end

      # The single judgement, shared by plan and apply so the two cannot
      # drift.
      def recheck(venv, older_than_days)
        blocker = venv.blocker
        return [:skip, blocker] if blocker

        age_skip(venv, older_than_days) || :ok
      end

      def age_skip(venv, older_than_days)
        _signal, at = venv.install
        case (verdict = Souji::FsScan.staleness(at, older_than_days))
        when :stale then nil
        when :unknown then [:skip, "cannot tell when packages were last installed"]
        else [:skip, "packages installed #{Souji::FsScan.days_phrase(verdict.last)} ago"]
        end
      end

      def build_item(venv, older_than_days)
        signal, install_at = venv.install
        project_at, truncated = Souji::FsScan.newest_mtime_under(venv.project)
        Souji::PlanItem.new(
          id: Souji::PlanItem.generate_id("python-venv"),
          recipe: "python-venv",
          path: venv.path,
          reason: reason_for(venv, install_at),
          size_bytes: Souji::FsScan.dir_size(venv.path),
          metadata: metadata_for(venv, signal, install_at, older_than_days)
                    .merge("project_at" => iso8601(project_at),
                           "project_at_truncated" => (true if truncated))
                    .compact
        )
      end

      def metadata_for(venv, signal, install_at, older_than_days)
        manifest, kind, = venv.manifest
        {
          "project" => venv.project,
          "manifest" => manifest,
          "manifest_kind" => kind,
          "python_version" => venv.python_version,
          "created_by" => venv.created_by,
          "interpreter_home" => venv.interpreter_home,
          "broken_interpreter" => (true if venv.broken_interpreter?),
          "install_at" => iso8601(install_at),
          "install_signal" => signal,
          "older_than_days" => older_than_days,
          "manifest_at" => iso8601(venv.manifest_at)
        }
      end

      def reason_for(venv, install_at)
        manifest, _kind, rebuild = venv.manifest
        days = Souji::FsScan.days_since(install_at)
        age = days ? "last install #{Souji::FsScan.days_phrase(days)} ago" : "last install unknown"
        caveat = "; its base interpreter is already gone" if venv.broken_interpreter?
        "Stale virtualenv (#{age}); #{manifest} can recreate it with `#{rebuild}`#{caveat}"
      end

      def iso8601(time)
        time&.utc&.iso8601
      end
    end
  end
end
