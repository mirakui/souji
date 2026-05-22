# multi-repo.rb
# Find every git repo immediately under ~/oss/ and target each one
# individually. This keeps each project's worktree pruning scoped so
# a misconfigured target can never escape into a sibling.

OSS_ROOT = File.expand_path("~/oss")

Dir.glob(File.join(OSS_ROOT, "*/.git")).each do |git_dir|
  repo = File.dirname(git_dir)
  target repo
end

recipe "git-worktree"

# Also clean dangling docker layers — no targets needed; the
# docker-image recipe operates against the docker daemon, not a path.
recipe "docker-image"
