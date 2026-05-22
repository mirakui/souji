# frozen_string_literal: true

require "souji/confirmation"

RSpec.describe Souji::Confirmation do
  let(:stdout) { StringIO.new }

  def fake_tty_stdin(input)
    io = StringIO.new(input)
    def io.tty? = true
    io
  end

  def fake_pipe_stdin(input)
    StringIO.new(input)
  end

  describe ".ask" do
    it "returns :proceed when --yes is set, regardless of stdin" do
      stdin = fake_pipe_stdin("")
      expect(
        described_class.ask(prompt: "proceed?", stdin: stdin, stdout: stdout, yes: true)
      ).to eq(:proceed)
    end

    it "returns :proceed when --dry-run is set" do
      stdin = fake_pipe_stdin("")
      expect(
        described_class.ask(prompt: "proceed?", stdin: stdin, stdout: stdout, dry_run: true)
      ).to eq(:proceed)
    end

    it "returns :proceed when stdin is a TTY and user types y" do
      stdin = fake_tty_stdin("y\n")
      expect(
        described_class.ask(prompt: "proceed?", stdin: stdin, stdout: stdout)
      ).to eq(:proceed)
    end

    it "returns :cancel when stdin is a TTY and user types anything else" do
      stdin = fake_tty_stdin("n\n")
      expect(
        described_class.ask(prompt: "proceed?", stdin: stdin, stdout: stdout)
      ).to eq(:cancel)
    end

    it "returns :cancel without prompting when stdin is not a TTY and --yes is not set" do
      stdin = fake_pipe_stdin("y\n")
      expect(
        described_class.ask(prompt: "proceed?", stdin: stdin, stdout: stdout)
      ).to eq(:cancel)
      expect(stdout.string).to include("non-interactive")
    end

    it "accepts uppercase Y as proceed" do
      stdin = fake_tty_stdin("Y\n")
      expect(
        described_class.ask(prompt: "proceed?", stdin: stdin, stdout: stdout)
      ).to eq(:proceed)
    end
  end
end
