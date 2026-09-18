# frozen_string_literal: true

require "souji/commands/apply_prompt"

RSpec.describe Souji::Commands::ApplyPrompt do
  def plan_with(*items)
    Souji::Plan.new(
      souji_plan_version: 1, souji_version: "0.1.0", generated_at: Time.now.iso8601,
      scenario_path: "/tmp/s.rb", scenario_content_sha256: "x",
      target_roots: ["/tmp"], items: items
    )
  end

  def item(recipe, path, size_bytes: nil, metadata: {})
    Souji::PlanItem.new(id: Souji::PlanItem.generate_id(recipe), recipe: recipe, path: path,
                        reason: "r", size_bytes: size_bytes, metadata: metadata)
  end

  def render(*items)
    described_class.new(plan_with(*items), "/tmp/plan.soujiplan").to_s
  end

  it "claims only what it believes will be freed on this host" do
    output = render(item("node-modules", "/tmp/a", size_bytes: 1_073_741_824))

    expect(output).to include("About to delete 1 items; at least 1.0 GB will be freed on this host.")
  end

  it "says nothing extra for a plan of sized, in-scope filesystem items" do
    # An ordinary plan must read as it always has: no qualifiers at all.
    output = render(item("node-modules", "/tmp/a", size_bytes: 100),
                    item("python-venv", "/tmp/b", size_bytes: 200))

    expect(output.lines.grep(/unknown size|docker VM|outside your target roots/)).to be_empty
    expect(output).to include("- node-modules:")
  end

  it "offers an unmeasurable item's upper bound as upside rather than as a promise" do
    output = render(item("uv-cache", "uv-cache://prune",
                         metadata: { "size_bytes_upper_bound" => 9_663_676_416 }),
                    item("node-modules", "/tmp/a", size_bytes: 100))

    expect(output).to include("1 item of unknown size may free up to 9.0 GB more.")
    expect(output).to match(/- uv-cache:\s+1 items\s+unknown, up to 9\.0 GB/)
  end

  it "says when an unmeasurable item has no upper bound either" do
    output = render(item("pnpm-store", "pnpm-store://prune"))

    expect(output).to include("1 item of unknown size may free up to 0 B more.")
    expect(output).to match(/- pnpm-store:\s+1 items\s+unknown size/)
  end

  it "reports VM bytes on their own line rather than as freed host space" do
    output = render(item("docker-build-cache", "docker-build-cache://prune",
                         size_bytes: 8_589_934_592,
                         metadata: { "host_space_unaffected" => true }))

    expect(output).to include("at least 0 B will be freed on this host.")
    expect(output).to include("8.0 GB is freed inside the docker VM, which does not free host disk.")
    expect(output).to match(/- docker-build-cache:\s+1 items\s+8\.0 GB inside the docker VM/)
  end

  it "names the recipes whose items sit outside the target roots" do
    # Read from the items' own scope_free metadata, not from the shape of
    # their paths, so the fact is only true in one place.
    output = render(item("uv-cache", "uv-cache://prune", metadata: { "scope_free" => true }),
                    item("docker-image", "docker-image://sha256:a", size_bytes: 10,
                                                                    metadata: { "scope_free" => true }),
                    item("node-modules", "/tmp/a", size_bytes: 10))

    expect(output).to include(
      "2 items sit outside your target roots (scope-free recipes: docker-image, uv-cache)."
    )
  end

  it "uses the singular for a single out-of-scope item" do
    output = render(item("uv-cache", "uv-cache://prune", size_bytes: 10,
                                                         metadata: { "scope_free" => true }))

    expect(output).to include("1 item sit")
  end

  it "says nothing about scope for an item that does not claim to be scope-free" do
    output = render(item("uv-cache", "uv-cache://prune", size_bytes: 10))

    expect(output).not_to include("outside your target roots")
  end

  it "lists recipes alphabetically with their counts" do
    output = render(item("python-venv", "/tmp/b", size_bytes: 10),
                    item("node-modules", "/tmp/a", size_bytes: 10))

    listed = output.lines.grep(/^  - /).map { |line| line[/- (\S+):/, 1] }
    expect(listed).to eq(%w[node-modules python-venv])
  end

  describe ".humanize_bytes" do
    it "scales in binary units" do
      expect(described_class.humanize_bytes(0)).to eq("0 B")
      expect(described_class.humanize_bytes(512)).to eq("512.0 B")
      expect(described_class.humanize_bytes(1024)).to eq("1.0 KB")
      expect(described_class.humanize_bytes((1024**4) * 3)).to eq("3.0 TB")
    end
  end
end
