# frozen_string_literal: true

require "souji/external/human_size"

RSpec.describe Souji::External::HumanSize do
  describe ".parse" do
    it "reads docker's SI units" do
      # docker prints decimal units: kB is 1000, not 1024. Treating them
      # as binary overstated every image by about 7% at GB scale.
      expect(described_class.parse("479MB")).to eq(479_000_000)
      expect(described_class.parse("13.7GB")).to eq(13_700_000_000)
      expect(described_class.parse("8.709GB")).to eq(8_709_000_000)
      expect(described_class.parse("625kB")).to eq(625_000)
      expect(described_class.parse("0B")).to eq(0)
    end

    it "reads Homebrew's binary quantities behind SI-looking labels" do
      expect(described_class.parse("34.6MB", base: :binary)).to eq(36_280_730)
      expect(described_class.parse("14.6KB", base: :binary)).to eq(14_950)
    end

    it "reads only the leading figure of docker's container size" do
      # The virtual size is shared with the image and is NOT freed by
      # `docker rm`; only the writable layer is. Reading the wrong one
      # overstates by ~700x on a typical stopped container.
      expect(described_class.parse("625kB (virtual 45.7MB)")).to eq(625_000)
      expect(described_class.parse("0B (virtual 474MB)")).to eq(0)
    end

    it "ignores a thousands separator in an adjacent file count" do
      expect(described_class.parse("1,707 files, 34.6MB", base: :binary)).to eq(36_280_730)
    end

    it "returns nil when there is no size to read" do
      expect(described_class.parse("N/A")).to be_nil
      expect(described_class.parse("")).to be_nil
      expect(described_class.parse("no size here")).to be_nil
      expect(described_class.parse("12 PB")).to be_nil
      expect(described_class.parse(nil)).to be_nil
    end
  end
end
