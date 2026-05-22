# frozen_string_literal: true

require_relative "lib/souji/version"

Gem::Specification.new do |spec|
  spec.name = "souji"
  spec.version = Souji::VERSION
  spec.authors = ["Issei Naruta"]
  spec.email = ["mimitako@gmail.com"]

  spec.summary = "Recipe-based local-disk cleanup tool (plan/apply)"
  spec.description = <<~DESC
    Souji crawls developer-workstation directories and produces a human-readable
    YAML plan of unneeded files (git worktrees, terraform provider caches,
    dangling docker image layers). A separate apply phase removes them with
    confirmation and per-item recipe re-verification.
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "README.md",
    "LICENSE",
    "souji.gemspec"
  ]
  spec.bindir = "exe"
  spec.executables = ["souji"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.3"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.60"
  spec.add_development_dependency "simplecov", "~> 0.22"

  spec.metadata = {
    "rubygems_mfa_required" => "true"
  }
end
