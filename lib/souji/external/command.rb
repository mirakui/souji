# frozen_string_literal: true

require "json"
require "open3"

module Souji
  module External
    # Runs an external tool and reports what it said, without ever raising
    # and without ever blocking forever.
    #
    # `Open3.capture3` was good enough while `docker image ls` was the only
    # caller. It is not good enough for the delegated-prune recipes, for
    # two reasons that both land on the user at the worst moment:
    #
    # - It has no timeout. `go clean -modcache` and `docker builder prune`
    #   run for minutes, and a tool that decides to prompt -- for a sudo
    #   password, for a registry login -- would hang `souji apply`
    #   *after* the user already consented to the deletion.
    # - A naive `wait_thr.join` with unread pipes deadlocks as soon as the
    #   child fills a pipe buffer, which `docker buildx du` does on a few
    #   hundred cache records.
    #
    # So: separate drain threads per stream, an explicit timeout with
    # TERM-then-KILL, an immediately closed stdin so anything that prompts
    # gets EOF instead of blocking, and a non-interactive environment.
    #
    # `Souji::Git::Command` deliberately does NOT move onto this. Its
    # `git -C <dir>` shape and its no-timeout assumption are load-bearing
    # across base_ref.rb, commit.rb, worktree_list.rb and
    # worktree_policy.rb, and `fetch` already carries its own BatchMode and
    # ConnectTimeout story. The asymmetry is intentional.
    module Command
      Result = Data.define(:stdout, :stderr, :exitstatus, :timed_out) do
        def success?
          !timed_out && exitstatus.zero?
        end
      end

      # Plan-time probes answer from a cache index and are quick.
      PROBE_TIMEOUT = 30
      # `docker system df` and `brew cleanup --dry-run` walk real trees.
      SLOW_PROBE_TIMEOUT = 120
      # Apply-time prune commands genuinely take minutes.
      PRUNE_TIMEOUT = 900

      # Kept as constants rather than recipe params: a scenario that set a
      # 30-second timeout on `go clean -modcache` would manufacture
      # spurious failures for itself.
      GRACE_SECONDS = 5

      # Only variables that suppress prompting, colour and background
      # updates belong here. Nothing that changes what a tool would
      # *do*: HOMEBREW_NO_INSTALL_FROM_API looked like it belonged, but it
      # switches Homebrew to its local tap, which changed the size
      # `brew cleanup --dry-run` reported by 230 MB and could trigger a
      # tap clone slow enough to blow the probe timeout. souji must
      # observe the tool the user has, not a differently configured one.
      NONINTERACTIVE_ENV = {
        "NO_COLOR" => "1",
        "CI" => "1",
        "DEBIAN_FRONTEND" => "noninteractive",
        "GIT_TERMINAL_PROMPT" => "0",
        "HOMEBREW_NO_AUTO_UPDATE" => "1",
        "HOMEBREW_NO_ENV_HINTS" => "1"
      }.freeze

      module_function

      def run(*argv, env: {}, timeout: PROBE_TIMEOUT)
        stdout, stderr, status, timed_out = spawn_and_drain(argv.flatten.map(&:to_s), env, timeout)
        Result.new(stdout: stdout, stderr: stderr, exitstatus: status, timed_out: timed_out)
      rescue SystemCallError => e
        # A tool that vanished between the PATH probe and here.
        Result.new(stdout: "", stderr: e.message, exitstatus: 127, timed_out: false)
      end

      def ok?(*argv, **)
        run(*argv, **).success?
      end

      # stdout with surrounding whitespace removed, or nil when the
      # command failed. Mirrors Souji::Git::Command.capture.
      def capture(*argv, **)
        result = run(*argv, **)
        result.success? ? result.stdout.strip : nil
      end

      def json(*argv, **)
        raw = capture(*argv, **)
        return nil if raw.nil? || raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      # The `--format '{{json .}}'` shape: one JSON object per line.
      # Unparseable lines are dropped rather than failing the batch.
      def json_lines(*argv, **)
        raw = capture(*argv, **)
        return [] if raw.nil?

        raw.each_line.filter_map do |line|
          next if line.strip.empty?

          begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
        end
      end

      def spawn_and_drain(argv, env, timeout)
        Open3.popen3(NONINTERACTIVE_ENV.merge(env), *argv) do |stdin, out, err, wait_thr|
          # popen3 always hands the child a stdin pipe, and an `in:` option
          # does not displace it -- so closing it here is what turns a
          # prompt into an immediate EOF instead of a hang.
          stdin.close
          readers = { stdout: Thread.new { out.read }, stderr: Thread.new { err.read } }
          timed_out = !wait_thr.join(timeout)
          reap(wait_thr) if timed_out
          [readers[:stdout].value.to_s, readers[:stderr].value.to_s, exit_status(wait_thr), timed_out]
        end
      end

      # TERM first so the tool can finish what it was writing, then KILL.
      def reap(wait_thr)
        Process.kill("TERM", wait_thr.pid)
        return if wait_thr.join(GRACE_SECONDS)

        Process.kill("KILL", wait_thr.pid)
        wait_thr.join
      rescue Errno::ESRCH
        nil
      end

      def exit_status(wait_thr)
        wait_thr.value.exitstatus || -1
      end
    end
  end
end
