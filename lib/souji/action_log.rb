# frozen_string_literal: true

require "json"
require "time"
require_relative "paths"

module Souji
  # Append-only JSONL action log emitted by `souji apply`.
  #
  # Default destinations (FR-017a, FR-017b):
  # - stderr always.
  # - Additionally a file under $XDG_STATE_HOME/souji/log/<UTC-ts>-<plan-basename>.jsonl
  #   unless --no-log-file is given. Best-effort: if the log dir cannot
  #   be created or the file cannot be opened, we fall back to stderr-only
  #   and emit a single warning.
  #
  # See contracts/action-log-schema.md for the line schema.
  class ActionLog
    def initialize(plan_path:, log_file_override: nil, no_log_file: false,
                   stderr: $stderr, now: Time.now.utc)
      @stderr = stderr
      @file = open_log_file(plan_path, log_file_override, no_log_file, now)
      @counts = { deleted: 0, trashed: 0, skipped: 0, failed: 0 }
      @start_time = now
    end

    def record(item:, outcome:, duration_ms:, reason: nil, error: nil, now: Time.now.utc) # rubocop:disable Metrics/ParameterLists
      entry = {
        "ts" => now.utc.iso8601(3),
        "item_id" => item.id,
        "recipe" => item.recipe,
        "path" => item.path,
        "outcome" => outcome.to_s,
        "duration_ms" => duration_ms
      }
      entry["reason"] = reason if reason
      entry["error"] = error if error
      emit(entry)
      @counts[outcome.to_sym] += 1 if @counts.key?(outcome.to_sym)
    end

    def summary(now: Time.now.utc)
      entry = {
        "summary" => true,
        "ts" => now.utc.iso8601(3),
        "deleted" => @counts[:deleted],
        "trashed" => @counts[:trashed],
        "skipped" => @counts[:skipped],
        "failed" => @counts[:failed],
        "total" => @counts.values.sum,
        "duration_ms" => ((now - @start_time) * 1000).to_i
      }
      emit(entry)
      entry
    end

    def close
      @file&.close
    end

    def file_path
      @file&.path
    end

    def failures?
      @counts[:failed].positive?
    end

    private

    def emit(entry)
      json = JSON.generate(entry)
      @stderr.puts(json)
      @file&.puts(json)
    end

    def open_log_file(plan_path, override, no_file, now)
      return nil if no_file

      path = override || Paths.default_log_file_for(plan_path: plan_path, now: now)
      begin
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "a")
      rescue StandardError => e
        @stderr.puts(
          "[souji] WARNING: cannot open action log #{path} (#{e.class}: #{e.message}); " \
          "continuing with stderr-only logging"
        )
        nil
      end
    end
  end
end
