# frozen_string_literal: true

require "psych"
require_relative "errors"
require_relative "plan_item"
require_relative "version"

module Souji
  # Plan — the deliverable of `souji plan`, persisted as YAML.
  #
  # On-disk format is documented in
  # specs/001-souji-cli-recipe-plan/contracts/plan-yaml-schema.md.
  # In-memory shape is the entity defined in data-model.md.
  #
  # Apply consumes the plan as the sole source of truth (FR-011a).
  class Plan
    SUPPORTED_VERSION = 1
    SYNTHETIC_URI_RE = %r{\A[a-z][a-z0-9-]*://}

    attr_reader :souji_plan_version, :souji_version, :generated_at,
                :scenario_path, :scenario_content_sha256,
                :target_roots, :items

    def initialize(souji_plan_version:, souji_version:, generated_at:, # rubocop:disable Metrics/ParameterLists
                   scenario_path:, scenario_content_sha256:,
                   target_roots:, items:)
      @souji_plan_version = souji_plan_version
      @souji_version = souji_version
      @generated_at = generated_at
      @scenario_path = scenario_path
      @scenario_content_sha256 = scenario_content_sha256
      @target_roots = target_roots.freeze
      @items = items.freeze
      validate_scope_containment!
      freeze
    end

    def self.load_yaml(path)
      doc = Psych.safe_load_file(path, permitted_classes: [Time, Date], aliases: false)
      version = doc.fetch("souji_plan_version")
      unless version == SUPPORTED_VERSION
        raise IncompatiblePlanError,
              "plan file #{path} declares souji_plan_version=#{version}; this build supports #{SUPPORTED_VERSION}"
      end

      items = (doc["items"] || []).map { |raw| reify_item(raw) }
      scenario = doc.fetch("scenario", {})

      new(
        souji_plan_version: version,
        souji_version: doc.fetch("souji_version"),
        generated_at: doc.fetch("generated_at"),
        scenario_path: scenario["path"],
        scenario_content_sha256: scenario["content_sha256"],
        target_roots: doc.fetch("target_roots"),
        items: items
      )
    end

    def self.reify_item(raw)
      PlanItem.new(
        id: raw.fetch("id"),
        recipe: raw.fetch("recipe"),
        path: raw.fetch("path"),
        reason: raw.fetch("reason"),
        size_bytes: raw["size_bytes"],
        metadata: raw["metadata"] || {}
      )
    end

    def dump_yaml(path)
      doc = {
        "souji_plan_version" => @souji_plan_version,
        "souji_version" => @souji_version,
        "generated_at" => @generated_at,
        "scenario" => {
          "path" => @scenario_path,
          "content_sha256" => @scenario_content_sha256
        },
        "target_roots" => @target_roots,
        "items" => @items.map { |i| serialize_item(i) }
      }
      File.write(path, Psych.safe_dump(doc, line_width: 120))
    end

    def summary
      by_recipe = Hash.new { |h, k| h[k] = { count: 0, bytes: 0 } }
      total_bytes = 0
      @items.each do |item|
        by_recipe[item.recipe][:count] += 1
        size = item.size_bytes || 0
        by_recipe[item.recipe][:bytes] += size
        total_bytes += size
      end
      {
        total_count: @items.size,
        total_bytes: total_bytes,
        by_recipe: by_recipe
      }
    end

    private

    def serialize_item(item)
      out = {
        "id" => item.id,
        "recipe" => item.recipe,
        "path" => item.path,
        "reason" => item.reason
      }
      out["size_bytes"] = item.size_bytes if item.size_bytes
      out["metadata"] = item.metadata unless item.metadata.empty?
      out
    end

    def validate_scope_containment!
      @items.each do |item|
        next if synthetic_uri?(item.path)
        next if under_any_root?(item.path)

        raise ScopeViolationError,
              "plan item #{item.id} path #{item.path} is not under any target_root (#{@target_roots.join(", ")})"
      end
    end

    def synthetic_uri?(path)
      SYNTHETIC_URI_RE.match?(path)
    end

    def under_any_root?(path)
      normalized = File.expand_path(path)
      @target_roots.any? do |root|
        normalized_root = File.expand_path(root)
        normalized == normalized_root || normalized.start_with?("#{normalized_root}/")
      end
    end
  end
end
