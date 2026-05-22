# frozen_string_literal: true

module Souji
  # Process exit codes for the souji CLI. Centralized here so the code
  # paths and contracts/cli-commands.md stay in sync.
  #
  # The numeric values follow Unix sysexits.h where reasonable:
  #   - EX_DATAERR (65) for scenario errors
  #   - EX_NOINPUT (66)-adjacent for plan errors
  #   - EX_CANTCREAT (73)-adjacent for apply partial failure
  #   - 130 = "process interrupted by SIGINT" convention for
  #     user-cancelled flows.
  module ExitCodes
    SUCCESS         = 0
    UNEXPECTED      = 1
    USAGE_ERROR     = 2
    SCENARIO_ERROR  = 65
    PLAN_ERROR      = 66
    APPLY_PARTIAL   = 73
    USER_CANCELLED  = 130
  end
end
