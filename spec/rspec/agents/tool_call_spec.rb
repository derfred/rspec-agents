require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::ToolCall do
  describe "#initialize" do
    it "requires a name" do
      tc = described_class.new(name: :search)
      expect(tc.name).to eq(:search)
    end

    it "converts string name to symbol" do
      tc = described_class.new(name: "search")
      expect(tc.name).to eq(:search)
    end

    it "defaults arguments to empty hash" do
      tc = described_class.new(name: :search)
      expect(tc.arguments).to eq({})
    end

    it "accepts arguments" do
      tc = described_class.new(name: :search, arguments: { query: "test" })
      expect(tc.arguments).to eq({ query: "test" })
    end

    it "accepts result" do
      tc = described_class.new(name: :search, result: { venues: [] })
      expect(tc.result).to eq({ venues: [] })
    end

    it "wraps metadata in Metadata class" do
      tc = described_class.new(name: :search, metadata: { latency: 100 })
      expect(tc.metadata).to be_a(RSpec::Agents::Metadata)
      expect(tc.metadata[:latency]).to eq(100)
    end
  end

  describe "#has_argument?" do
    let(:tc) { described_class.new(name: :search, arguments: { query: "test", "location" => "Berlin" }) }

    it "returns true for existing symbol key" do
      expect(tc.has_argument?(:query)).to be true
    end

    it "returns true for existing string key" do
      expect(tc.has_argument?("location")).to be true
    end

    it "returns false for missing key" do
      expect(tc.has_argument?(:missing)).to be false
    end
  end

  describe "#argument" do
    let(:tc) { described_class.new(name: :search, arguments: { query: "test", "location" => "Berlin" }) }

    it "returns value for symbol key" do
      expect(tc.argument(:query)).to eq("test")
    end

    it "returns value for string key" do
      expect(tc.argument("location")).to eq("Berlin")
    end

    it "returns nil for missing key" do
      expect(tc.argument(:missing)).to be_nil
    end
  end

  describe "#matches_params?" do
    let(:tc) { described_class.new(name: :search, arguments: { query: "Stuttgart venues", capacity: 50 }) }

    it "returns true for nil params" do
      expect(tc.matches_params?(nil)).to be true
    end

    it "returns true for empty params" do
      expect(tc.matches_params?({})).to be true
    end

    it "matches exact values" do
      expect(tc.matches_params?({ capacity: 50 })).to be true
      expect(tc.matches_params?({ capacity: 100 })).to be false
    end

    it "matches regexp patterns" do
      expect(tc.matches_params?({ query: /stuttgart/i })).to be true
      expect(tc.matches_params?({ query: /berlin/i })).to be false
    end

    it "matches with proc" do
      expect(tc.matches_params?({ capacity: ->(v) { v >= 50 } })).to be true
      expect(tc.matches_params?({ capacity: ->(v) { v > 50 } })).to be false
    end

    it "requires all params to match" do
      expect(tc.matches_params?({ query: /stuttgart/i, capacity: 50 })).to be true
      expect(tc.matches_params?({ query: /stuttgart/i, capacity: 100 })).to be false
    end
  end

  describe "#to_h" do
    it "returns hash representation" do
      tc = described_class.new(
        name:      :search,
        arguments: { query: "test" },
        result:    { found: true },
        metadata:  { latency: 100 }
      )

      expect(tc.to_h).to eq({
        name:      :search,
        arguments: { query: "test" },
        result:    { found: true },
        metadata:  { latency: 100 }
      })
    end
  end

  describe "#==" do
    it "equals another ToolCall with same name and arguments" do
      a = described_class.new(name: :search, arguments: { q: "test" })
      b = described_class.new(name: :search, arguments: { q: "test" })
      expect(a).to eq(b)
    end

    it "does not equal different name" do
      a = described_class.new(name: :search)
      b = described_class.new(name: :filter)
      expect(a).not_to eq(b)
    end

    it "does not equal different arguments" do
      a = described_class.new(name: :search, arguments: { q: "a" })
      b = described_class.new(name: :search, arguments: { q: "b" })
      expect(a).not_to eq(b)
    end
  end
end
