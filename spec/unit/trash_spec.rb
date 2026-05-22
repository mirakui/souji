# frozen_string_literal: true

require "souji/trash"

RSpec.describe Souji::Trash do
  describe ".dispose" do
    it "returns [:failed, ...] for a path that does not exist" do
      with_tmp_dir do |dir|
        missing = File.join(dir, "absent")
        outcome, msg = described_class.dispose(missing, warn_io: StringIO.new)
        expect(outcome).to eq(:failed)
        expect(msg).to include(missing)
      end
    end

    it "trashes a file using the platform backend when one is available" do
      with_tmp_dir do |dir|
        file = File.join(dir, "trashable.txt")
        File.write(file, "x")
        result = described_class.dispose(file, warn_io: StringIO.new)
        # `:trashed` if a backend exists on this host, `:deleted` if it
        # had to fall back. Either way the file must be gone.
        expect(%i[trashed deleted]).to include(result)
        expect(File.exist?(file)).to be false
      end
    end

    it "falls back to hard-delete with a stderr warning when no backend exists" do
      with_tmp_dir do |dir|
        file = File.join(dir, "x")
        File.write(file, "x")
        warn = StringIO.new
        allow(described_class).to receive(:pick_backend).and_return(:none)
        outcome = described_class.dispose(file, warn_io: warn)
        expect(outcome).to eq(:deleted)
        expect(warn.string).to match(/hard-deleting/i)
        expect(File.exist?(file)).to be false
      end
    end

    it "removes whole directories" do
      with_tmp_dir do |dir|
        sub = File.join(dir, "subdir")
        FileUtils.mkdir_p(sub)
        File.write(File.join(sub, "a"), "x")
        result = described_class.dispose(sub, warn_io: StringIO.new)
        expect(%i[trashed deleted]).to include(result)
        expect(Dir.exist?(sub)).to be false
      end
    end
  end

  describe ".pick_backend" do
    it "returns a known backend symbol or :none" do
      expect(%i[trash_cli osascript gio_trash none]).to include(described_class.pick_backend)
    end
  end
end
