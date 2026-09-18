# frozen_string_literal: true

require "souji/external/command"

RSpec.describe Souji::External::Command do
  describe ".run" do
    it "reports stdout, stderr and the exit status" do
      result = described_class.run("sh", "-c", "echo out; echo err >&2; exit 3")

      expect(result.stdout).to eq("out\n")
      expect(result.stderr).to eq("err\n")
      expect(result.exitstatus).to eq(3)
      expect(result.timed_out).to be false
      expect(result).not_to be_success
    end

    it "reports success for a zero exit" do
      expect(described_class.run("true")).to be_success
    end

    it "returns a failed result rather than raising when the command does not exist" do
      result = described_class.run("souji-definitely-not-a-real-binary-12345")

      expect(result).not_to be_success
      expect(result.exitstatus).to eq(127)
    end

    it "kills a command that outruns its timeout and says so" do
      result = described_class.run("sleep", "30", timeout: 1)

      expect(result.timed_out).to be true
      expect(result).not_to be_success
    end

    it "does not deadlock on output larger than a pipe buffer" do
      # A naive wait_thr.join with unread pipes hangs here, which is why
      # each stream gets its own drain thread. `docker buildx du` produces
      # this much on a few hundred cache records.
      result = described_class.run("sh", "-c", "yes souji | head -c 400000", timeout: 20)

      expect(result).to be_success
      expect(result.stdout.bytesize).to eq(400_000)
    end

    it "gives a command that reads stdin EOF rather than letting it block" do
      # Without in: File::NULL this times out: a tool that decides to
      # prompt would hang `souji apply` after the user already consented.
      result = described_class.run("cat", timeout: 5)

      expect(result.timed_out).to be false
      expect(result.stdout).to eq("")
    end

    it "passes the non-interactive environment to the child" do
      result = described_class.run("sh", "-c", "echo $NO_COLOR-$GIT_TERMINAL_PROMPT-$HOMEBREW_NO_AUTO_UPDATE")

      expect(result.stdout.strip).to eq("1-0-1")
    end

    it "lets a caller add to the environment" do
      result = described_class.run("sh", "-c", "echo $SOUJI_SPEC", env: { "SOUJI_SPEC" => "here" })

      expect(result.stdout.strip).to eq("here")
    end
  end

  describe ".ok?" do
    it "is true only for a successful command" do
      expect(described_class.ok?("true")).to be true
      expect(described_class.ok?("false")).to be false
    end
  end

  describe ".capture" do
    it "returns stripped stdout on success and nil on failure" do
      expect(described_class.capture("sh", "-c", "echo ' padded '")).to eq("padded")
      expect(described_class.capture("sh", "-c", "echo out; exit 1")).to be_nil
    end
  end

  describe ".json" do
    it "parses a single JSON document" do
      expect(described_class.json("sh", "-c", %(echo '{"a":1}'))).to eq({ "a" => 1 })
    end

    it "returns nil for a failure, for empty output and for unparseable output" do
      expect(described_class.json("false")).to be_nil
      expect(described_class.json("true")).to be_nil
      expect(described_class.json("sh", "-c", "echo not-json")).to be_nil
    end
  end

  describe ".json_lines" do
    it "parses one object per line and drops the lines it cannot parse" do
      script = %(printf '{"a":1}\\n\\n{oops}\\n{"a":2}\\n')

      expect(described_class.json_lines("sh", "-c", script)).to eq([{ "a" => 1 }, { "a" => 2 }])
    end

    it "returns an empty array for a failed command" do
      expect(described_class.json_lines("false")).to eq([])
    end
  end
end
