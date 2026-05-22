# frozen_string_literal: true

require "securerandom"

module Souji
  # A single deletion candidate inside a Souji::Plan.
  #
  # Identity is the `id` field: "<recipe-name>:<ULID>". Equality is
  # value-based (Data.define). Instances are frozen at construction;
  # mutate by building a new instance instead.
  #
  # See contracts/plan-yaml-schema.md for the on-disk representation.
  class PlanItem < Data.define(:id, :recipe, :path, :reason, :size_bytes, :metadata) # rubocop:disable Style/DataInheritance
    # Recipe-prefix : 26-char Crockford base32 ULID
    ID_FORMAT = /\A[a-z][a-z0-9-]*:[0-9A-HJKMNP-TV-Z]{26}\z/

    # Crockford base32 alphabet (no I, L, O, U)
    CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".chars.freeze

    def self.new(id:, recipe:, path:, reason:, size_bytes: nil, metadata: nil) # rubocop:disable Metrics/ParameterLists
      raise ArgumentError, "id format invalid: #{id.inspect}" unless ID_FORMAT.match?(id)

      super(id: id, recipe: recipe, path: path, reason: reason,
            size_bytes: size_bytes, metadata: metadata || {}).freeze
    end

    # Generate a fresh per-item identifier of the form
    # "<recipe-name>:<ULID>". Time-prefixed so ids are roughly
    # K-sortable across a single plan generation.
    def self.generate_id(recipe_name)
      "#{recipe_name}:#{generate_ulid}"
    end

    def self.generate_ulid
      time_part = encode_crockford((Time.now.to_i * 1000) + (Time.now.usec / 1000), 10)
      rand_part = encode_crockford(SecureRandom.random_number(2**80), 16)
      "#{time_part}#{rand_part}"
    end

    def self.encode_crockford(int, length)
      out = String.new(capacity: length)
      length.times do
        out.prepend(CROCKFORD[int & 0x1f])
        int >>= 5
      end
      out
    end
  end
end
