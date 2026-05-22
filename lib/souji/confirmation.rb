# frozen_string_literal: true

module Souji
  # Interactive y/N prompt that fronts every non-`--yes` invocation of
  # apply (R9 / FR-013). Returns :proceed or :cancel.
  module Confirmation
    module_function

    def ask(prompt:, stdin: $stdin, stdout: $stdout, yes: false, dry_run: false)
      return :proceed if yes || dry_run

      unless stdin.tty?
        stdout.puts(
          "[souji] non-interactive (stdin is not a TTY) and --yes was not given; refusing to proceed"
        )
        return :cancel
      end

      stdout.print("#{prompt} [y/N]: ")
      stdout.flush
      response = stdin.gets&.strip
      return :proceed if response&.downcase == "y"

      :cancel
    end
  end
end
