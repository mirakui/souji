# frozen_string_literal: true

require "json"
require "souji/action_log"
require "souji/plan_item"
require "tmpdir"

RSpec.describe Souji::ActionLog do
  let(:stderr) { StringIO.new }
  let(:now) { Time.utc(2026, 5, 22, 13, 50, 0) }
  let(:item) do
    Souji::PlanItem.new(
      id: "git-worktree:01HZQK2H4Z9YPC7A0F0F4F0F4F",
      recipe: "git-worktree",
      path: "/some/path",
      reason: "stub"
    )
  end

  around do |example|
    saved = ENV.to_hash
    Dir.mktmpdir("souji-log-home-") do |home|
      ENV["HOME"] = home
      ENV["XDG_STATE_HOME"] = File.join(home, ".local", "state")
      example.run
    end
  ensure
    ENV.replace(saved)
  end

  describe "default destination" do
    it "writes to $XDG_STATE_HOME/souji/log/<ts>-<basename>.jsonl in addition to stderr" do
      log = described_class.new(plan_path: "/tmp/weekly.soujiplan", stderr: stderr, now: now)
      log.record(item: item, outcome: :trashed, duration_ms: 42)
      log.summary(now: now + 1)
      log.close

      expected_path = File.join(ENV.fetch("XDG_STATE_HOME"), "souji", "log",
                                "2026-05-22T13-50-00Z-weekly.jsonl")
      expect(File.file?(expected_path)).to be true
      file_lines = File.read(expected_path).each_line.map { |l| JSON.parse(l) }
      expect(file_lines.size).to eq(2)
      expect(file_lines.first["outcome"]).to eq("trashed")
      expect(file_lines.last["summary"]).to be true

      stderr_lines = stderr.string.each_line.map { |l| JSON.parse(l) }
      expect(stderr_lines).to eq(file_lines)
    end
  end

  describe "--log-file override" do
    it "writes to the explicit path instead of XDG_STATE_HOME" do
      with_tmp_dir do |dir|
        explicit = File.join(dir, "out.jsonl")
        log = described_class.new(plan_path: "/tmp/x.soujiplan", log_file_override: explicit,
                                  stderr: stderr, now: now)
        log.record(item: item, outcome: :deleted, duration_ms: 10)
        log.close
        expect(File.file?(explicit)).to be true
        expect(File.read(explicit)).to include("deleted")
      end
    end
  end

  describe "--no-log-file" do
    it "suppresses the file destination but keeps stderr emission" do
      log = described_class.new(plan_path: "/tmp/x.soujiplan", no_log_file: true,
                                stderr: stderr, now: now)
      log.record(item: item, outcome: :skipped, duration_ms: 5, reason: "already gone")
      log.close
      expect(log.file_path).to be_nil
      expect(stderr.string).to include("skipped")
      expect(stderr.string).to include("already gone")
    end
  end

  describe "unwritable log dir fallback" do
    it "emits a one-line warning and continues with stderr only" do
      bad = File.join("/etc/no-permission-here", "log.jsonl")
      log = described_class.new(plan_path: "/tmp/x.soujiplan", log_file_override: bad,
                                stderr: stderr, now: now)
      log.record(item: item, outcome: :deleted, duration_ms: 1)
      log.close
      expect(stderr.string).to match(/cannot open action log/i)
      expect(log.file_path).to be_nil
      expect(stderr.string).to include("deleted")
    end
  end

  describe "summary line" do
    it "counts outcomes and reports total + duration_ms" do
      log = described_class.new(plan_path: "/tmp/x.soujiplan", no_log_file: true,
                                stderr: stderr, now: now)
      2.times { log.record(item: item, outcome: :deleted, duration_ms: 1) }
      log.record(item: item, outcome: :trashed, duration_ms: 2)
      log.record(item: item, outcome: :skipped, duration_ms: 3, reason: "drifted")
      log.record(item: item, outcome: :failed, duration_ms: 4, error: "EACCES")
      result = log.summary(now: now + 10)
      log.close
      expect(result["deleted"]).to eq(2)
      expect(result["trashed"]).to eq(1)
      expect(result["skipped"]).to eq(1)
      expect(result["failed"]).to eq(1)
      expect(result["total"]).to eq(5)
      expect(result["duration_ms"]).to be >= 10_000
      expect(log.failures?).to be true
    end
  end
end
