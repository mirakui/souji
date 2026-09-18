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
    # `:leading` handles docker's container form, `"625kB (virtual 45.7MB)"`,
    # where only the first figure is the writable layer `docker rm`
    # actually frees.
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
        return nil unless text.is_a?(String)

        match = text.match(NUMBER)
        return nil unless match

        units = UNITS.fetch(base)
        multiplier = units[match[2].upcase]
        return nil unless multiplier

        (match[1].to_f * multiplier).round
      end
    end
  end
end
