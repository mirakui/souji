# frozen_string_literal: true

require "json"
require "souji/fs_scan"

RSpec.describe Souji::FsScan do
  describe ".walk_dirs" do
    it "yields the root and every descendant directory, parents first" do
      with_tmp_dir do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "a", "b"))
        FileUtils.mkdir_p(File.join(tmp, "c"))

        visited = []
        described_class.walk_dirs(tmp, skip: []) { |dir| visited << dir }

        expect(visited).to eq([tmp, File.join(tmp, "a"), File.join(tmp, "a", "b"), File.join(tmp, "c")])
      end
    end

    it "yields siblings in sorted order so enumeration is deterministic" do
      with_tmp_dir do |tmp|
        %w[zeta alpha middle].each { |name| FileUtils.mkdir_p(File.join(tmp, name)) }

        visited = []
        described_class.walk_dirs(tmp, skip: []) { |dir| visited << File.basename(dir) }

        expect(visited).to eq([File.basename(tmp), "alpha", "middle", "zeta"])
      end
    end

    it "prunes directories whose basename is in skip, without yielding them" do
      with_tmp_dir do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "node_modules", "deep"))
        FileUtils.mkdir_p(File.join(tmp, "src"))

        visited = []
        described_class.walk_dirs(tmp) { |dir| visited << dir }

        expect(visited).to eq([tmp, File.join(tmp, "src")])
      end
    end

    it "stops descending when the block returns :prune, but still yielded that directory" do
      with_tmp_dir do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "stop", "deep"))

        visited = []
        described_class.walk_dirs(tmp, skip: []) do |dir|
          visited << dir
          :prune if File.basename(dir) == "stop"
        end

        expect(visited).to eq([tmp, File.join(tmp, "stop")])
      end
    end

    it "never descends into a symlinked directory" do
      with_tmp_dir do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "real", "inner"))
        File.symlink(File.join(tmp, "real"), File.join(tmp, "link"))

        visited = []
        described_class.walk_dirs(tmp, skip: []) { |dir| visited << dir }

        expect(visited).to eq([tmp, File.join(tmp, "real"), File.join(tmp, "real", "inner")])
      end
    end

    it "does not hang on a symlink loop" do
      with_tmp_dir do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "a"))
        File.symlink(tmp, File.join(tmp, "a", "up"))

        visited = []
        described_class.walk_dirs(tmp, skip: []) { |dir| visited << dir }

        expect(visited).to eq([tmp, File.join(tmp, "a")])
      end
    end

    it "keeps walking past an unreadable directory" do
      with_tmp_dir do |tmp|
        locked = File.join(tmp, "locked")
        FileUtils.mkdir_p(File.join(locked, "inner"))
        FileUtils.mkdir_p(File.join(tmp, "readable"))
        File.chmod(0o000, locked)

        begin
          visited = []
          described_class.walk_dirs(tmp, skip: []) { |dir| visited << File.basename(dir) }

          expect(visited).to include("locked", "readable")
        ensure
          File.chmod(0o755, locked)
        end
      end
    end

    it "yields nothing for a path that is not a directory" do
      with_tmp_dir do |tmp|
        file = File.join(tmp, "plain.txt")
        File.write(file, "x")

        expect { |b| described_class.walk_dirs(file, &b) }.not_to yield_control
        expect { |b| described_class.walk_dirs(File.join(tmp, "missing"), &b) }.not_to yield_control
      end
    end
  end

  describe ".dir_size" do
    it "sums the regular files at and below the path" do
      with_tmp_dir do |tmp|
        File.write(File.join(tmp, "top"), "a" * 10)
        FileUtils.mkdir_p(File.join(tmp, "sub"))
        File.write(File.join(tmp, "sub", "nested"), "b" * 5)

        expect(described_class.dir_size(tmp)).to eq(15)
      end
    end

    it "counts a symlink as zero rather than following it" do
      with_tmp_dir do |tmp|
        target = File.join(tmp, "target")
        FileUtils.mkdir_p(target)
        File.write(File.join(target, "big"), "x" * 100)

        cache_user = File.join(tmp, "user")
        FileUtils.mkdir_p(cache_user)
        File.symlink(File.join(target, "big"), File.join(cache_user, "linked"))
        File.symlink(target, File.join(cache_user, "linked_dir"))

        expect(described_class.dir_size(cache_user)).to eq(0)
      end
    end

    it "returns zero for a missing path" do
      with_tmp_dir do |tmp|
        expect(described_class.dir_size(File.join(tmp, "nope"))).to eq(0)
      end
    end
  end

  describe ".newest_mtime" do
    it "returns the newest mtime among the paths that exist" do
      with_tmp_dir do |tmp|
        old = File.join(tmp, "old")
        new = File.join(tmp, "new")
        File.write(old, "x")
        File.write(new, "x")
        File.utime(Time.now - 10_000, Time.now - 10_000, old)

        expect(described_class.newest_mtime([old, new, File.join(tmp, "missing"), nil]))
          .to be_within(5).of(File.mtime(new))
      end
    end

    it "returns nil when nothing exists" do
      with_tmp_dir do |tmp|
        expect(described_class.newest_mtime([File.join(tmp, "a"), nil])).to be_nil
      end
    end
  end

  describe ".newest_mtime_under" do
    it "finds the newest mtime in the tree and reports an untruncated walk" do
      with_tmp_dir do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "deep"))
        stale = File.join(tmp, "deep", "stale")
        fresh = File.join(tmp, "fresh")
        File.write(stale, "x")
        File.write(fresh, "x")
        File.utime(Time.now - 100_000, Time.now - 100_000, stale)

        newest, truncated = described_class.newest_mtime_under(tmp, skip: [])

        expect(newest).to be_within(5).of(File.mtime(fresh))
        expect(truncated).to be false
      end
    end

    it "reports truncated: true once the entry budget runs out" do
      with_tmp_dir do |tmp|
        5.times { |i| File.write(File.join(tmp, "f#{i}"), "x") }

        _newest, truncated = described_class.newest_mtime_under(tmp, skip: [], budget: 1)

        expect(truncated).to be true
      end
    end

    it "returns nil for an empty tree" do
      with_tmp_dir do |tmp|
        expect(described_class.newest_mtime_under(tmp, skip: [])).to eq([nil, false])
      end
    end
  end

  describe ".read_text" do
    # A workstation with no LANG set has Encoding.default_external =
    # US-ASCII, and then File.read + JSON.parse on a package.json with a
    # non-ASCII description raises Encoding::InvalidByteSequenceError while
    # transcoding -- which aborted a whole `souji plan` run.
    it "returns UTF-8 text regardless of the default external encoding" do
      with_tmp_dir do |tmp|
        path = File.join(tmp, "package.json")
        File.binwrite(path, %({"name":"\xE5\xAF\xBF"}))

        text = with_external_encoding(Encoding::US_ASCII) { described_class.read_text(path) }

        expect(text.encoding).to eq(Encoding::UTF_8)
        expect(JSON.parse(text)["name"]).to eq("寿")
      end
    end

    it "scrubs bytes that are not valid UTF-8 rather than raising" do
      with_tmp_dir do |tmp|
        path = File.join(tmp, "broken.cfg")
        File.binwrite(path, "home = /usr/\xFF\xFEbin")

        text = described_class.read_text(path)

        expect(text).to be_valid_encoding
        expect(text).to start_with("home = /usr/")
      end
    end

    it "returns nil for a file it cannot read" do
      with_tmp_dir do |tmp|
        expect(described_class.read_text(File.join(tmp, "missing"))).to be_nil
      end
    end
  end

  describe ".staleness" do
    it "treats a missing threshold as no gate at all" do
      expect(described_class.staleness(nil, nil)).to eq(:stale)
      expect(described_class.staleness(Time.now, nil)).to eq(:stale)
    end

    it "refuses rather than passes when the threshold cannot be evaluated" do
      expect(described_class.staleness(nil, 90)).to eq(:unknown)
    end

    it "reports stale at or past the threshold and fresh before it" do
      expect(described_class.staleness(Time.now - (90 * 86_400), 90)).to eq(:stale)
      expect(described_class.staleness(Time.now - (10 * 86_400), 90)).to eq([:fresh, 10])
    end
  end

  describe ".days_phrase" do
    it "pluralizes" do
      expect(described_class.days_phrase(1)).to eq("1 day")
      expect(described_class.days_phrase(2)).to eq("2 days")
    end
  end

  describe ".within_any?" do
    it "accepts the root itself and anything under it" do
      expect(described_class.within_any?("/a/b", ["/a"])).to be true
      expect(described_class.within_any?("/a", ["/a"])).to be true
    end

    it "rejects a sibling whose name merely starts with the root" do
      expect(described_class.within_any?("/ab", ["/a"])).to be false
      expect(described_class.within_any?("/c", ["/a", "/b"])).to be false
    end

    it "expands both sides before comparing" do
      expect(described_class.within_any?("/a/b/../b/c", ["/a"])).to be true
    end
  end

  describe ".days_since" do
    it "floors the elapsed whole days" do
      now = Time.now
      expect(described_class.days_since(now - (90 * 86_400), now: now)).to eq(90)
      expect(described_class.days_since(now - (90 * 86_400) + 60, now: now)).to eq(89)
      expect(described_class.days_since(now, now: now)).to eq(0)
    end

    it "passes nil straight through" do
      expect(described_class.days_since(nil)).to be_nil
    end
  end
end
