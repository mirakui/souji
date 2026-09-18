# frozen_string_literal: true

require "psych"
require_relative "errors"
require_relative "plan_item"
require_relative "version"
require_relative "fs_scan"

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

    def initialize(souji_plan_version:, souji_version:, generated_at:,
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

    # Aggregate counts and bytes, keeping three kinds of byte apart.
    #
    # `size_bytes` means "souji believes this much will actually be freed
    # on this host", and only figures that meet that bar are summed into
    # `total_bytes`. Two kinds do not:
    #
    # - An item with no `size_bytes` is one whose tool cannot say what is
    #   reclaimable (`uv cache prune` has no dry run). Its whole-cache size
    #   goes to `upper_bound_bytes` instead. Summing an upper bound into
    #   the total would turn "at least this much" into a promise.
    # - An item flagged `host_space_unaffected` frees space inside a VM
    #   disk image that does not shrink, so the host's `df` will not move.
    #   Those bytes are real, but not here, and they go to `vm_bytes`.
    def summary
      buckets = Hash.new { |h, k| h[k] = { count: 0, bytes: 0, unsized: 0, upper_bound: 0, vm_bytes: 0 } }
      totals = { count: 0, bytes: 0, unsized: 0, upper_bound: 0, vm_bytes: 0 }
      @items.each { |item| accumulate(item, buckets[item.recipe], totals) }
      {
        total_count: totals[:count],
        total_bytes: totals[:bytes],
        unsized_count: totals[:unsized],
        upper_bound_bytes: totals[:upper_bound],
        vm_bytes: totals[:vm_bytes],
        by_recipe: buckets
      }
    end

    private

    def accumulate(item, bucket, totals)
      bucket[:count] += 1
      totals[:count] += 1
      if item.size_bytes.nil?
        bucket[:unsized] += 1
        totals[:unsized] += 1
        bound = upper_bound_for(item)
        bucket[:upper_bound] += bound
        totals[:upper_bound] += bound
      elsif vm_only?(item)
        bucket[:vm_bytes] += item.size_bytes
        totals[:vm_bytes] += item.size_bytes
      else
        bucket[:bytes] += item.size_bytes
        totals[:bytes] += item.size_bytes
      end
    end

    def upper_bound_for(item)
      value = item.metadata["size_bytes_upper_bound"]
      value.is_a?(Integer) ? value : 0
    end

    def vm_only?(item)
      item.metadata["host_space_unaffected"] == true
    end

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
      Souji::FsScan.within_any?(path, @target_roots)
    end
  end
end
