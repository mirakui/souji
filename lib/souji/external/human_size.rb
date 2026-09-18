# frozen_string_literal: true

module Souji
  module External
    # Parses the human-readable sizes external tools print.
    #
    # The `base:` argument is not a nicety -- the sources disagree, and
    # getting it wrong misreports the headline number souji exists to
    # report:
    #
    # - **docker** prints SI units: `kB` is 1000, `13.7GB` is 13.7e9.
    # - **Homebrew** prints binary quantities behind SI-looking labels:
    #   its `34.6MB` is 34.6 * 1048576.
    #
    # `parse_all` handles docker's container form,
    # `"625kB (virtual 45.7MB)"`, where the first figure is the writable
    # layer `docker rm` actually frees and the second is shared with the
    # image.
    module HumanSize
      SI = { "B" => 1, "KB" => 1000, "MB" => 1000**2, "GB" => 1000**3, "TB" => 1000**4 }.freeze
      BINARY = { "B" => 1, "KB" => 1024, "MB" => 1024**2, "GB" => 1024**3, "TB" => 1024**4 }.freeze
      UNITS = { si: SI, binary: BINARY }.freeze

      # Homebrew writes thousands separators into the file counts it prints
      # alongside the size, so the number is matched, not merely scanned.
      NUMBER = /(\d+(?:\.\d+)?)\s*([KMGT]?B)\b/i

      module_function

      # Bytes, or nil when there is no size to read -- `"N/A"`, `""`, an
      # unrecognised unit. Zero is a real answer and comes back as 0.
      def parse(text, base: :si)
        parse_all(text, base: base).first
      end

      # Every size in the string, in order, so a caller reading a compound
      # form does not need a second regex of its own.
      def parse_all(text, base: :si)
        return [] unless text.is_a?(String)

        units = UNITS.fetch(base)
        text.scan(NUMBER).filter_map do |number, unit|
          multiplier = units[unit.upcase]
          (number.to_f * multiplier).round if multiplier
        end
      end
    end
  end
end
