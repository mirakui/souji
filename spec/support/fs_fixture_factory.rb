# frozen_string_literal: true

require "fileutils"
require "json"

module Souji
  module SpecSupport
    # Builds the on-disk shapes the pure-filesystem recipes look for.
    #
    # Deliberately writes real files rather than stubbing the filesystem:
    # every one of these recipes is a set of claims about what a directory
    # layout means, and a stub can only ever confirm the claim we already
    # believed.
    module FsFixtureFactory
      # A terraform root with a populated `.terraform/`.
      #
      # `entries` are the `.terraform/` children to create; a String makes
      # a directory holding one stub file, a Hash { name => contents }
      # makes files.
      def make_terraform_root(dir, lockfile: true, config: true, entries: %w[providers],
                              workspace: nil, backend: nil)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "main.tf"), "resource \"null_resource\" \"a\" {}\n") if config
        write_terraform_lockfile(dir) if lockfile

        tf = File.join(dir, ".terraform")
        FileUtils.mkdir_p(tf)
        entries.each { |entry| make_terraform_entry(tf, entry) }
        File.write(File.join(tf, "environment"), workspace) if workspace
        write_backend_stub(tf, backend) if backend
        dir
      end

      def write_terraform_lockfile(dir, provider: "aws", version: "5.0.0")
        File.write(File.join(dir, ".terraform.lock.hcl"), <<~HCL)
          provider "registry.terraform.io/hashicorp/#{provider}" {
            version = "#{version}"
          }
        HCL
      end

      # A zip-magic file, which is what a real saved plan is.
      def write_saved_plan(dir, name: "tfplan")
        path = File.join(dir, name)
        File.binwrite(path, "PK\x03\x04#{"\x00" * 16}")
        path
      end

      # A node project: package.json, a lockfile, and a node_modules tree
      # carrying the package manager's install receipt.
      def make_node_project(dir, package_json: {}, lockfile: "pnpm-lock.yaml",
                            receipt: ".modules.yaml", nested: false)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "package.json"), JSON.generate({ "name" => "fixture" }.merge(package_json))) if
          package_json != :none
        File.write(File.join(dir, lockfile), "lockfileVersion: 9\n") if lockfile

        modules = File.join(dir, "node_modules")
        FileUtils.mkdir_p(File.join(modules, ".bin"))
        File.write(File.join(modules, receipt), "hoistPattern: []\n") if receipt
        File.write(File.join(modules, "left-pad", "index.js").tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, "x")
        make_node_project(File.join(modules, ".pnpm", "inner"), nested: false) if nested
        dir
      end

      # A PEP 405 virtualenv beside a regeneration manifest.
      def make_python_venv(dir, venv: ".venv", manifest: "uv.lock", cfg: :default, interpreter: "bin/python")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, manifest), "version = 1\n") if manifest

        root = File.join(dir, venv)
        site = File.join(root, "lib", "python3.14", "site-packages")
        FileUtils.mkdir_p(site)
        File.write(File.join(site, "marker.py"), "x")
        write_pyvenv_cfg(root, cfg) if cfg
        if interpreter
          path = File.join(root, interpreter)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "#!/bin/sh\n")
        end
        root
      end

      def write_pyvenv_cfg(root, cfg)
        FileUtils.mkdir_p(root)
        body = cfg == :default ? { "home" => "/usr/bin", "version_info" => "3.14.0", "uv" => "0.9.22" } : cfg
        File.write(File.join(root, "pyvenv.cfg"), body.map { |k, v| "#{k} = #{v}" }.join("\n"))
      end

      # Backdate every path so an `older_than_days:` filter fires.
      def backdate(*paths, days:)
        at = Time.now - (days * 86_400)
        paths.flatten.each { |path| File.utime(at, at, path) }
      end

      private

      def make_terraform_entry(tf, entry)
        case entry
        when Hash
          entry.each { |name, contents| File.write(File.join(tf, name), contents) }
        else
          dir = File.join(tf, entry)
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, "stub"), "x" * 32)
        end
      end

      def write_backend_stub(tf, backend)
        File.write(File.join(tf, "terraform.tfstate"),
                   JSON.generate({ "version" => 3, "backend" => { "type" => backend, "config" => {} } }))
      end
    end
  end
end

RSpec.configure do |config|
  config.include Souji::SpecSupport::FsFixtureFactory
end
