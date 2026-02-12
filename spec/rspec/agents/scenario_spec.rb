require "spec_helper"

RSpec.describe RSpec::Agents::Scenario do
  let(:scenario_data) do
    {
      id:          "test-001",
      name:        "Test Scenario",
      goal:        "A test goal",
      context:     ["Context item 1", "Context item 2"],
      personality: "Professional"
    }
  end

  let(:scenario) { described_class.new(scenario_data, index: 0) }

  describe "#initialize" do
    it "stores the data with symbol keys" do
      expect(scenario.data).to eq(scenario_data)
    end

    it "converts string keys to symbols" do
      string_data = { "id" => "test", "name" => "Test" }
      s = described_class.new(string_data)

      expect(s.data).to eq({ id: "test", name: "Test" })
    end

    it "stores optional index" do
      expect(scenario.index).to eq(0)
    end
  end

  describe "#[]" do
    it "accesses data via [] operator with symbol keys" do
      expect(scenario[:id]).to eq("test-001")
      expect(scenario[:name]).to eq("Test Scenario")
      expect(scenario[:goal]).to eq("A test goal")
    end

    it "accesses data via [] operator with string keys" do
      expect(scenario["id"]).to eq("test-001")
      expect(scenario["name"]).to eq("Test Scenario")
    end

    it "returns nil for non-existent keys" do
      expect(scenario[:nonexistent]).to be_nil
    end
  end

  describe "dot notation access" do
    it "provides access via method calls" do
      expect(scenario.id).to eq("test-001")
      expect(scenario.name).to eq("Test Scenario")
      expect(scenario.goal).to eq("A test goal")
      expect(scenario.context).to eq(["Context item 1", "Context item 2"])
      expect(scenario.personality).to eq("Professional")
    end

    it "raises NoMethodError for undefined attributes" do
      expect { scenario.missing_attribute }.to raise_error(NoMethodError)
    end

    it "responds to attributes in data" do
      expect(scenario.respond_to?(:id)).to be true
      expect(scenario.respond_to?(:name)).to be true
      expect(scenario.respond_to?(:missing)).to be false
    end
  end

  describe "#identifier" do
    it "generates a stable identifier based on data hash" do
      identifier1 = scenario.identifier
      identifier2 = scenario.identifier

      expect(identifier1).to eq(identifier2)
      expect(identifier1).to match(/^scenario_[a-f0-9]{8}$/)
    end

    it "generates different identifiers for different data" do
      other_data = scenario_data.merge(name: "Different Scenario")
      other_scenario = described_class.new(other_data, index: 1)

      expect(scenario.identifier).not_to eq(other_scenario.identifier)
    end

    it "generates same identifier regardless of key order" do
      reordered_data = {
        personality: "Professional",
        goal:        "A test goal",
        id:          "test-001",
        context:     ["Context item 1", "Context item 2"],
        name:        "Test Scenario"
      }
      reordered_scenario = described_class.new(reordered_data, index: 0)

      expect(scenario.identifier).to eq(reordered_scenario.identifier)
    end
  end

  describe "#to_h" do
    it "returns a copy of the data hash" do
      result = scenario.to_h

      expect(result).to eq(scenario_data)
      expect(result).not_to be(scenario.data)
    end
  end

  describe "#to_json" do
    it "converts to JSON" do
      json = scenario.to_json
      parsed = JSON.parse(json)

      expect(parsed["id"]).to eq("test-001")
      expect(parsed["name"]).to eq("Test Scenario")
    end
  end

  describe "#inspect" do
    it "includes identifier and name" do
      inspect_str = scenario.inspect

      expect(inspect_str).to include("Scenario")
      expect(inspect_str).to include(scenario.identifier)
      expect(inspect_str).to include("Test Scenario")
    end

    it "uses id if name is not present" do
      s = described_class.new({ id: "test-id" })
      inspect_str = s.inspect

      expect(inspect_str).to include("test-id")
    end
  end

  describe "#==" do
    it "returns true for scenarios with same data" do
      other = described_class.new(scenario_data)

      expect(scenario).to eq(other)
    end

    it "returns false for scenarios with different data" do
      other = described_class.new({ id: "different" })

      expect(scenario).not_to eq(other)
    end

    it "returns false for non-Scenario objects" do
      expect(scenario).not_to eq(scenario_data)
      expect(scenario).not_to eq("test")
    end
  end

  describe "#hash" do
    it "allows scenarios to be used in hashes" do
      other = described_class.new(scenario_data)
      hash = { scenario => "value" }

      expect(hash[other]).to eq("value")
    end
  end
end
