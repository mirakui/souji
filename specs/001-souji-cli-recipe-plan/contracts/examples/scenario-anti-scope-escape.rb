# Anti-example: per-recipe `targets:` escapes the scenario-level target set.
# Expected behavior: `souji plan` exits with code 65 and stderr identifies
# the offending `recipe` call as attempting to enumerate paths outside
# the declared scope (FR-019).
# Used as a negative fixture in spec/unit/scenario_spec.rb.

target File.expand_path("~/work")

# "~/personal" is NOT under the declared "~/work" target — this should be
# rejected at scenario evaluation time, not at plan-write time.
recipe "git-worktree", targets: [File.expand_path("~/personal")]
