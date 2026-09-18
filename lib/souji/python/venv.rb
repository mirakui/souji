# frozen_string_literal: true

require_relative "../fs_scan"

module Souji
  module Python
    # A Python virtualenv, and everything souji needs to know to judge
    # whether it is safe to recreate.
    #
    # Detection is structural -- a PEP 405 `pyvenv.cfg` plus an
    # interpreter -- not name-based. A name list would match any directory
    # somebody happened to call `venv` while missing every venv called
    # something else (`env`, `venv312`, `.virtualenv`), and the structural
    # check costs one extra stat per visited directory.
    #
    # Conda and mamba environments carry `conda-meta/` and no
    # `pyvenv.cfg`, so they never match. That is correct: removing one
    # needs `conda env remove` to keep conda's own index consistent.
    #
    # Nothing here raises.
    class Venv
      CONFIG = "pyvenv.cfg"
      INTERPRETERS = [
        File.join("bin", "python"),
        File.join("bin", "python3"),
        File.join("Scripts", "python.exe")
      ].freeze

      # Regeneration manifests in priority order, with the command that
      # rebuilds from each. Lockfiles rank first because they make the
      # rebuild exact; `pyproject.toml` and `requirements.txt` only pin
      # loosely, but this recipe's promise is "reinstallable", not
      # "byte-identical", so the reason string names which kind it found.
      MANIFESTS = [
        ["uv.lock", "uv", "uv sync"],
        ["poetry.lock", "poetry", "poetry install"],
        ["pdm.lock", "pdm", "pdm install"],
        ["Pipfile.lock", "pipenv", "pipenv sync"],
        ["requirements.txt", "pip", "pip install -r requirements.txt"],
        ["pyproject.toml", "pep621", "pip install -e ."],
        ["setup.py", "setuptools", "pip install -e ."]
      ].freeze

      attr_reader :path

      def initialize(path)
        @path = File.expand_path(path.to_s)
      end

      def config_path
        File.join(@path, CONFIG)
      end

      # The project directory whose manifest recreates this venv: the
      # venv's immediate parent only, never an ancestor walk. A
      # `services/api/.venv` with only a repository-root pyproject.toml is
      # deliberately left alone -- souji must not assume a monorepo layout
      # applies.
      def project
        File.dirname(@path)
      end

      def venv?
        return false unless Souji::FsScan.directory_no_follow?(@path)
        return false unless File.file?(config_path)

        INTERPRETERS.any? { |relative| interpreter_present?(File.join(@path, relative)) }
      end

      # `python -m venv` and `uv venv` both create `bin/python` as a symlink
      # into the base interpreter. Once that interpreter is upgraded away
      # the link dangles and `File.exist?` -- which follows symlinks --
      # says no. That would make `venv?` reject precisely the venv
      # `broken_interpreter?` exists to describe, and would send the walk
      # down through all of site-packages looking for one.
      def interpreter_present?(path)
        File.symlink?(path) || File.exist?(path)
      end

      # [basename, kind, rebuild command] or nil.
      def manifest
        MANIFESTS.find { |name, _kind, _cmd| File.file?(File.join(project, name)) }
      end

      def manifest_at
        name = manifest&.first
        name && Souji::FsScan.mtime_or_nil(File.join(project, name))
      end

      def python_version
        config["version_info"]
      end

      def interpreter_home
        config["home"]
      end

      # Which tool created the venv, when it says so. `uv venv` and
      # `virtualenv` both record their version; plain `python -m venv`
      # records nothing.
      def created_by
        %w[uv virtualenv].filter_map { |key| "#{key} #{config[key]}" if config[key] }.first
      end

      # A venv whose base interpreter has been upgraded away is already
      # non-functional, which is a stronger reason to remove it, not a
      # weaker one. So this never gates -- it goes in the reason string,
      # where it is the most reassuring thing a reviewer can read.
      def broken_interpreter?
        home = interpreter_home
        !home.nil? && !Souji::FsScan.directory_no_follow?(home)
      end

      # Never propose the virtualenv souji is running inside. Compared by
      # realpath rather than expand_path: a target root reached through a
      # symlink (`~/work` -> `/Volumes/dev/work`) yields a different
      # string for the same directory, and the shell's VIRTUAL_ENV is
      # whichever spelling the user happened to cd through. Comparing the
      # spellings would let souji trash the venv it is running in.
      def active?
        mine = real_path(@path)
        %w[VIRTUAL_ENV CONDA_PREFIX].any? do |var|
          value = ENV.fetch(var, nil)
          next false if value.nil? || value.empty?

          real_path(value) == mine
        end
      end

      # [signal, time] for the most recent install into this venv, or nil.
      # `site-packages`' own mtime is bumped by every pip or uv install,
      # which makes it the precise "last install here" signal.
      def install
        candidates = install_signals.filter_map do |relative|
          at = Souji::FsScan.mtime_or_nil(File.join(@path, relative))
          [relative, at] if at
        end
        candidates.max_by(&:last)
      end

      def blocker
        return "no #{CONFIG}, so this is not a virtualenv" unless venv?
        return "this is the active virtualenv" if active?
        return "no sibling manifest, so the venv could not be recreated" unless manifest

        nil
      end

      private

      # Globbed relative to `base:` rather than by interpolating @path into
      # the pattern: a venv under a directory containing `[`, `]`, `{`,
      # `}`, `*` or `?` would otherwise match nothing, and the age gate
      # would silently fall back to `bin/`'s mtime -- which is older than
      # site-packages, so a freshly installed venv could be proposed.
      def install_signals
        site_packages = Dir.glob(File.join("lib", "python*", "site-packages"), base: @path).sort
        site_packages + [File.join("lib", "site-packages"), "bin", "Scripts", CONFIG]
      end

      # `pyvenv.cfg` is `key = value` lines. Anything else is ignored and
      # nothing raises -- a config we cannot read yields no metadata, and
      # `venv?` has already established the file exists.
      def config
        @config ||= parse_config
      end

      def real_path(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end

      def parse_config
        (Souji::FsScan.read_text(config_path) || "").lines(chomp: true).each_with_object({}) do |line, acc|
          key, _, value = line.partition("=")
          next if value.empty?

          acc[key.strip] = value.strip
        end
      end
    end
  end
end
