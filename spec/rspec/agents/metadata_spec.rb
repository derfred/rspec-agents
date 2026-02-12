require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::Metadata do
  describe "#initialize" do
    it "accepts a hash and normalizes keys to symbols" do
      metadata = described_class.new("foo" => "bar", baz: "qux")
      expect(metadata[:foo]).to eq("bar")
      expect(metadata[:baz]).to eq("qux")
    end

    it "accepts an empty hash" do
      metadata = described_class.new
      expect(metadata.empty?).to be true
    end
  end

  describe "#[]" do
    it "provides indifferent access with symbols" do
      metadata = described_class.new(foo: "bar")
      expect(metadata[:foo]).to eq("bar")
    end

    it "provides indifferent access with strings" do
      metadata = described_class.new(foo: "bar")
      expect(metadata["foo"]).to eq("bar")
    end

    it "returns nil for missing keys" do
      metadata = described_class.new
      expect(metadata[:missing]).to be_nil
    end
  end

  describe "#[]=" do
    it "sets values with symbol keys" do
      metadata = described_class.new
      metadata[:foo] = "bar"
      expect(metadata[:foo]).to eq("bar")
    end

    it "sets values with string keys normalized to symbols" do
      metadata = described_class.new
      metadata["foo"] = "bar"
      expect(metadata[:foo]).to eq("bar")
    end
  end

  describe "#key?" do
    it "returns true for existing keys" do
      metadata = described_class.new(foo: "bar")
      expect(metadata.key?(:foo)).to be true
      expect(metadata.key?("foo")).to be true
    end

    it "returns false for missing keys" do
      metadata = described_class.new
      expect(metadata.key?(:missing)).to be false
    end
  end

  describe "#fetch" do
    it "returns value for existing key" do
      metadata = described_class.new(foo: "bar")
      expect(metadata.fetch(:foo)).to eq("bar")
    end

    it "returns default for missing key" do
      metadata = described_class.new
      expect(metadata.fetch(:missing, "default")).to eq("default")
    end

    it "calls block for missing key" do
      metadata = described_class.new
      expect(metadata.fetch(:missing) { "from_block" }).to eq("from_block")
    end

    it "raises KeyError for missing key without default" do
      metadata = described_class.new
      expect { metadata.fetch(:missing) }.to raise_error(KeyError)
    end
  end

  describe "#merge" do
    it "returns new Metadata with merged values" do
      metadata = described_class.new(a: 1, b: 2)
      merged = metadata.merge(b: 3, c: 4)

      expect(merged[:a]).to eq(1)
      expect(merged[:b]).to eq(3)
      expect(merged[:c]).to eq(4)
    end

    it "does not modify the original" do
      metadata = described_class.new(a: 1)
      metadata.merge(a: 2)
      expect(metadata[:a]).to eq(1)
    end
  end

  describe "#to_h" do
    it "returns a hash copy" do
      metadata = described_class.new(foo: "bar")
      hash = metadata.to_h
      expect(hash).to eq({ foo: "bar" })
    end
  end

  describe "#==" do
    it "equals another Metadata with same values" do
      a = described_class.new(foo: "bar")
      b = described_class.new(foo: "bar")
      expect(a).to eq(b)
    end

    it "equals a hash with same values" do
      metadata = described_class.new(foo: "bar")
      expect(metadata).to eq({ foo: "bar" })
    end

    it "does not equal different values" do
      a = described_class.new(foo: "bar")
      b = described_class.new(foo: "baz")
      expect(a).not_to eq(b)
    end

    it "equals nested structures after deep conversion" do
      a = described_class.new
      a.scope!(:tracing) { |t| t.model = "claude" }

      b = described_class.new
      b.scope!(:tracing) { |t| t.model = "claude" }

      expect(a).to eq(b)
      expect(a).to eq({ tracing: { model: "claude" } })
    end
  end

  describe "dynamic attributes" do
    it "supports getter via method call" do
      metadata = described_class.new(model: "claude-3-5-sonnet")
      expect(metadata.model).to eq("claude-3-5-sonnet")
    end

    it "supports setter via method call" do
      metadata = described_class.new
      metadata.model = "claude-3-5-sonnet"
      expect(metadata[:model]).to eq("claude-3-5-sonnet")
    end

    it "returns nil for missing attributes" do
      metadata = described_class.new
      expect(metadata.missing_attr).to be_nil
    end
  end

  describe "#scope!" do
    it "creates nested Metadata for single key" do
      metadata = described_class.new
      metadata.scope!(:tracing) do |t|
        t.latency_ms = 2340
      end

      expect(metadata[:tracing]).to be_a(described_class)
      expect(metadata[:tracing][:latency_ms]).to eq(2340)
    end

    it "creates nested Metadata for multiple keys" do
      metadata = described_class.new
      metadata.scope!(:tracing, :tokens) do |t|
        t.input = 1523
        t.output = 342
      end

      expect(metadata[:tracing][:tokens][:input]).to eq(1523)
      expect(metadata[:tracing][:tokens][:output]).to eq(342)
    end

    it "reuses existing nested Metadata" do
      metadata = described_class.new
      metadata.scope!(:tracing) { |t| t.model = "claude" }
      metadata.scope!(:tracing) { |t| t.latency_ms = 2340 }

      expect(metadata[:tracing][:model]).to eq("claude")
      expect(metadata[:tracing][:latency_ms]).to eq(2340)
    end

    it "returns the innermost scope" do
      metadata = described_class.new
      inner = metadata.scope!(:tracing, :tokens)
      inner.input = 100

      expect(metadata.dig(:tracing, :tokens, :input)).to eq(100)
    end

    it "raises ArgumentError when called without keys" do
      metadata = described_class.new
      expect { metadata.scope! }.to raise_error(ArgumentError, /requires at least one key/)
    end

    it "supports the full design document example" do
      metadata = described_class.new

      metadata.scope!(:tracing) do |t|
        t.model = "claude-3-5-sonnet"
        t.latency_ms = 2340

        t.scope!(:tokens) do |tok|
          tok.input = 1523
          tok.output = 342
        end
      end

      metadata.scope!(:custom) do |c|
        c.request_id = "abc-123"
      end

      expect(metadata.to_h).to eq({
        tracing: {
          model:      "claude-3-5-sonnet",
          latency_ms: 2340,
          tokens:     { input: 1523, output: 342 }
        },
        custom:  { request_id: "abc-123" }
      })
    end
  end

  describe "#dig" do
    it "returns value for single key" do
      metadata = described_class.new(foo: "bar")
      expect(metadata.dig(:foo)).to eq("bar")
    end

    it "returns value for nested keys" do
      metadata = described_class.new
      metadata.scope!(:tracing, :tokens) { |t| t.input = 1523 }

      expect(metadata.dig(:tracing, :tokens, :input)).to eq(1523)
    end

    it "returns nil for missing keys" do
      metadata = described_class.new
      expect(metadata.dig(:missing)).to be_nil
      expect(metadata.dig(:missing, :nested)).to be_nil
    end

    it "returns nil for partial path" do
      metadata = described_class.new(foo: "bar")
      expect(metadata.dig(:foo, :nested)).to be_nil
    end

    it "returns nil when called with no keys" do
      metadata = described_class.new(foo: "bar")
      expect(metadata.dig).to be_nil
    end
  end

  describe "#to_h" do
    it "deeply converts nested Metadata to hashes" do
      metadata = described_class.new
      metadata.scope!(:tracing) { |t| t.model = "claude" }

      result = metadata.to_h
      expect(result).to eq({ tracing: { model: "claude" } })
      expect(result[:tracing]).to be_a(Hash)
      expect(result[:tracing]).not_to be_a(described_class)
    end
  end
end
