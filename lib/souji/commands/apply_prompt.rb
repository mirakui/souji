# frozen_string_literal: true

require_relative "../plan"

module Souji
  module Commands
    # Renders the summary a user reads immediately before consenting to a
    # deletion. It lives in its own class because it is the most
    # consequential text souji produces and the easiest to get quietly
    # wrong: the headline is a byte count, and a byte count that overstates
    # what will be freed is worse than no byte count at all.
    #
    # So the headline claims only what souji believes will actually be
    # freed on this host, and up to three qualifiers follow it:
    #
    #   About to delete 34 items; at least 1.2 GB will be freed on this host.
    #     3 items of unknown size may free up to 18.1 GB more.
    #     8.7 GB is freed inside the docker VM, which does not free host disk.
    #     4 items sit outside your target roots (scope-free recipes: uv-cache).
    #     - brew-cache:            1 items   652.8 MB
    #     - uv-cache:              1 items   unknown, up to 9.3 GB
    #
    # Each qualifier is suppressed when its count is zero, so a plan made
    # entirely of sized, in-scope filesystem items reads as it always has.
    class ApplyPrompt
      UNITS = %w[B KB MB GB TB].freeze

      def initialize(plan, plan_path)
        @plan = plan
        @plan_path = plan_path
        @summary = plan.summary
      end

      def to_s
        ([
          "Souji plan: #{@plan_path}",
          "About to delete #{@summary[:total_count]} items; " \
          "at least #{humanize_bytes(@summary[:total_bytes])} will be freed on this host."
        ] + qualifier_lines + recipe_lines).join("\n")
      end

      def self.humanize_bytes(bytes)
        return "0 B" if bytes.zero?

        value = bytes.to_f
        index = 0
        while value >= 1024 && index < UNITS.size - 1
          value /= 1024
          index += 1
        end
        format("%<value>.1f %<unit>s", value: value, unit: UNITS[index])
      end

      private

      def qualifier_lines
        lines = []
        lines << unsized_line if @summary[:unsized_count].positive?
        lines << vm_line if @summary[:vm_bytes].positive?
        lines.concat(scope_free_lines)
      end

      def unsized_line
        "  #{pluralize(@summary[:unsized_count], "item")} of unknown size " \
          "may free up to #{humanize_bytes(@summary[:upper_bound_bytes])} more."
      end

      # Pruning inside a Lima or Docker Desktop VM does not shrink the VM's
      # disk image, so these bytes are real but land somewhere the user's
      # `df` will not show.
      def vm_line
        "  #{humanize_bytes(@summary[:vm_bytes])} is freed inside the docker VM, " \
          "which does not free host disk."
      end

      # souji's containment promise is that nothing outside the declared
      # targets is touched. The recipes acting on a tool's own store are the
      # exception, and this prompt is where saying so actually matters.
      def scope_free_lines
        escaping = @plan.items.select { |item| Souji::Plan::SYNTHETIC_URI_RE.match?(item.path) }
        return [] if escaping.empty?

        ["  #{pluralize(escaping.size, "item")} sit outside your target roots " \
         "(scope-free recipes: #{escaping.map(&:recipe).uniq.sort.join(", ")})."]
      end

      def recipe_lines
        @summary[:by_recipe].sort_by { |name, _| name }.map do |recipe, info|
          format("  - %-22<recipe>s %<count>d items%<size>s",
                 recipe: "#{recipe}:", count: info[:count], size: recipe_size(info))
        end
      end

      def recipe_size(info)
        parts = []
        parts << humanize_bytes(info[:bytes]) if info[:bytes].positive?
        parts << "#{humanize_bytes(info[:vm_bytes])} inside the docker VM" if info[:vm_bytes].positive?
        parts << unsized_phrase(info) if info[:unsized].positive?
        parts.empty? ? "" : "   #{parts.join(", ")}"
      end

      def unsized_phrase(info)
        return "unknown size" unless info[:upper_bound].positive?

        "unknown, up to #{humanize_bytes(info[:upper_bound])}"
      end

      def pluralize(count, noun)
        "#{count} #{noun}#{"s" unless count == 1}"
      end

      def humanize_bytes(bytes)
        self.class.humanize_bytes(bytes)
      end
    end
  end
end
