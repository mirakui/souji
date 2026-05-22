# Anti-example: typo in recipe name.
# Expected behavior: `souji plan` exits with code 65 and stderr names
# the unknown recipe plus the list of registered recipes.
# Used as a negative fixture in spec/unit/scenario_spec.rb.

target File.expand_path("~/work")

recipe "git-worktreee"  # intentional typo — recipe does not exist
