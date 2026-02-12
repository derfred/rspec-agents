# frozen_string_literal: true

require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::StableExampleId do
  # Mock RSpec example for testing
  let(:mock_example_group) do
    parent_group = double("parent_group", description: "Agent")
    child_group = double("child_group",
      description:   "venue search",
      parent_groups: [child_group, parent_group]
    )
    allow(child_group).to receive(:parent_groups).and_return([child_group, parent_group])
    child_group
  end

  let(:mock_example) do
    double("example",
      description:   "returns results",
      example_group: mock_example_group
    )
  end

  describe ".generate" do
    it "creates a StableExampleId instance" do
      result = described_class.generate(mock_example)
      expect(result).to be_a(RSpec::Agents::StableExampleId)
    end
  end

  describe "#to_s" do
    it "returns ID with example: prefix" do
      stable_id = described_class.generate(mock_example)
      expect(stable_id.to_s).to start_with("example:")
    end

    it "returns 12-character hash" do
      stable_id = described_class.generate(mock_example)
      hash_part = stable_id.to_s.delete_prefix("example:")
      expect(hash_part.length).to eq(12)
    end

    it "returns consistent ID for same example" do
      id1 = described_class.generate(mock_example)
      id2 = described_class.generate(mock_example)
      expect(id1.to_s).to eq(id2.to_s)
    end
  end

  describe "#canonical_path" do
    it "builds path from describe/context/it hierarchy" do
      stable_id = described_class.generate(mock_example)
      expect(stable_id.canonical_path).to eq("Agent::venue search::returns results")
    end

    context "with whitespace in descriptions" do
      let(:mock_example) do
        double("example",
          description:   "  returns   results  ",
          example_group: mock_example_group
        )
      end

      it "normalizes whitespace" do
        stable_id = described_class.generate(mock_example)
        expect(stable_id.canonical_path).to eq("Agent::venue search::returns results")
      end
    end

    context "with empty description" do
      let(:mock_example) do
        double("example",
          description:   "",
          example_group: mock_example_group
        )
      end

      it "uses placeholder for empty descriptions" do
        stable_id = described_class.generate(mock_example)
        expect(stable_id.canonical_path).to include("(anonymous)")
      end
    end
  end

  describe "#hash_value" do
    it "returns 12-character hex string" do
      stable_id = described_class.generate(mock_example)
      expect(stable_id.hash_value).to match(/\A[a-f0-9]{12}\z/)
    end
  end

  describe "scenario integration" do
    let(:scenario) do
      RSpec::Agents::Scenario.new({
        name: "corporate event",
        goal: "Find a venue for 50 people"
      })
    end

    it "appends scenario identifier to canonical path" do
      stable_id = described_class.generate(mock_example, scenario: scenario)
      expect(stable_id.canonical_path).to match(/@scenario_[a-f0-9]{8}$/)
    end

    it "produces different IDs for different scenarios" do
      scenario1 = RSpec::Agents::Scenario.new({ name: "event1", goal: "goal1" })
      scenario2 = RSpec::Agents::Scenario.new({ name: "event2", goal: "goal2" })

      id1 = described_class.generate(mock_example, scenario: scenario1)
      id2 = described_class.generate(mock_example, scenario: scenario2)

      expect(id1.to_s).not_to eq(id2.to_s)
    end

    context "with hash scenario" do
      it "handles raw hash scenarios" do
        stable_id = described_class.generate(mock_example, scenario: { name: "test", goal: "test goal" })
        expect(stable_id.canonical_path).to match(/@data_[a-f0-9]{8}$/)
      end
    end
  end

  describe "equality" do
    it "equals another StableExampleId with same value" do
      id1 = described_class.generate(mock_example)
      id2 = described_class.generate(mock_example)
      expect(id1).to eq(id2)
    end

    it "equals string representation" do
      stable_id = described_class.generate(mock_example)
      expect(stable_id).to eq(stable_id.to_s)
    end

    it "can be used in hashes" do
      id1 = described_class.generate(mock_example)
      id2 = described_class.generate(mock_example)

      hash = { id1 => "value" }
      expect(hash[id2]).to eq("value")
    end
  end

  describe "#inspect" do
    it "shows ID and canonical path" do
      stable_id = described_class.generate(mock_example)
      expect(stable_id.inspect).to include("StableExampleId")
      expect(stable_id.inspect).to include("example:")
      expect(stable_id.inspect).to include("Agent::venue search::returns results")
    end
  end
end
