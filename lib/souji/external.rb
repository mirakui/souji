# frozen_string_literal: true

module Souji
  # Namespace for the thin, never-raising plumbing the recipes that shell
  # out to external tools share. Mirrors Souji::Git in shape and intent.
  module External
    autoload :Command, "souji/external/command"
    autoload :HumanSize, "souji/external/human_size"
    autoload :Docker, "souji/external/docker"
    autoload :DelegatedPrune, "souji/external/delegated_prune"
  end
end
