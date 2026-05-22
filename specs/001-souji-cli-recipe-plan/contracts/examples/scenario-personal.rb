# personal.rb
# Whole-workstation cleanup. Terraform is restricted to infra dirs
# because Souji should never touch terraform caches inside playground
# repos (which intentionally pin old provider versions for testing).

target File.expand_path("~/work")
target File.expand_path("~/playground")

with_targets "~/work/infra", "~/playground/tf" do
  recipe "terraform-provider"
end

# git-worktree applies to both targets (default scope)
recipe "git-worktree"

# Only prune docker layers older than 30 days
recipe "docker-image", older_than_days: 30
