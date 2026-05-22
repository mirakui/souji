# weekly.rb
# Weekly cleanup of ~/work — run via:
#   souji plan ~/cleanups/weekly.rb -o weekly.soujiplan
#   souji apply weekly.soujiplan

target File.expand_path("~/work")

recipe "git-worktree"
recipe "docker-image"
