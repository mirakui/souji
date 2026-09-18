# frozen_string_literal: true

require "souji/external/command"

module Souji
  module SpecSupport
    # Stubs `Souji::External::Command.run`, which every tool-delegating
    # recipe funnels through. Having one seam is most of the argument for
    # the shared layer existing: with eight recipes each calling
    # `Open3.capture3` directly there would be nothing to stub.
    #
    # Registered argv patterns are matched longest-prefix-first, so a
    # specific stub wins over a general one.
    module ExternalCommandStub
      # Anything in here, in an argv that does not also carry --dry-run,
      # mutates the tool's state. `#enumerate` must never invoke one:
      # `souji plan` is structurally read-only.
      MUTATING_WORDS = %w[prune clean rm uninstall cleanup remove].freeze

      def stub_external(*argv, stdout: "", stderr: "", exitstatus: 0, timed_out: false)
        external_stubs << { argv: argv.flatten.map(&:to_s), stdout: stdout, stderr: stderr,
                            exitstatus: exitstatus, timed_out: timed_out }
        install_external_stub
      end

      # Every argv `Souji::External::Command.run` was asked to run.
      def external_calls
        @external_calls ||= []
      end

      def external_stubs
        @external_stubs ||= []
      end

      # Fails unless every recorded call was read-only. Used to hold
      # `#enumerate` to souji's central promise.
      def expect_only_read_only_calls!
        offenders = external_calls.reject { |argv| read_only?(argv) }
        expect(offenders).to be_empty,
                             "expected no mutating commands, got: #{offenders.map { |a| a.join(" ") }.join("; ")}"
      end

      def read_only?(argv)
        return true if argv.include?("--dry-run")

        argv.none? { |word| MUTATING_WORDS.include?(word) }
      end

      private

      def install_external_stub
        return if @external_stub_installed

        @external_stub_installed = true
        allow(Souji::External::Command).to receive(:run) do |*argv, **_options|
          flat = argv.flatten.map(&:to_s)
          external_calls << flat
          canned = best_match(flat)
          Souji::External::Command::Result.new(
            stdout: canned&.fetch(:stdout) || "",
            stderr: canned&.fetch(:stderr) || "",
            exitstatus: canned ? canned[:exitstatus] : 127,
            timed_out: canned ? canned[:timed_out] : false
          )
        end
      end

      def best_match(argv)
        external_stubs
          .select { |stub| argv.first(stub[:argv].size) == stub[:argv] }
          .max_by { |stub| stub[:argv].size }
      end
    end
  end
end

RSpec.configure do |config|
  config.include Souji::SpecSupport::ExternalCommandStub
end
