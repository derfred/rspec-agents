require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::AgentResponse do
  describe "#initialize" do
    it "requires text" do
      response = described_class.new(text: "Hello!")
      expect(response.text).to eq("Hello!")
    end

    it "defaults tool_calls to empty array" do
      response = described_class.new(text: "Hello!")
      expect(response.tool_calls).to eq([])
    end

    it "accepts ToolCall objects" do
      tc = RSpec::Agents::ToolCall.new(name: :search, arguments: { q: "test" })
      response = described_class.new(text: "Hello!", tool_calls: [tc])
      expect(response.tool_calls.first).to be_a(RSpec::Agents::ToolCall)
      expect(response.tool_calls.first.name).to eq(:search)
    end

    it "accepts Metadata object" do
      metadata = RSpec::Agents::Metadata.new(latency: 100)
      response = described_class.new(text: "Hello!", metadata: metadata)
      expect(response.metadata).to be_a(RSpec::Agents::Metadata)
      expect(response.metadata[:latency]).to eq(100)
    end
  end

  describe "#has_tool_call?" do
    let(:response) do
      described_class.new(
        text:       "Found venues",
        tool_calls: [
          RSpec::Agents::ToolCall.new(name: :search_venues, arguments: { location: "Stuttgart", capacity: 50 }),
          RSpec::Agents::ToolCall.new(name: :filter_results, arguments: { max_price: 1000 })
        ]
      )
    end

    it "returns true when tool was called" do
      expect(response.has_tool_call?(:search_venues)).to be true
    end

    it "returns true with string name" do
      expect(response.has_tool_call?("search_venues")).to be true
    end

    it "returns false when tool was not called" do
      expect(response.has_tool_call?(:book_venue)).to be false
    end

    it "returns true with matching params" do
      expect(response.has_tool_call?(:search_venues, params: { capacity: 50 })).to be true
    end

    it "returns false with non-matching params" do
      expect(response.has_tool_call?(:search_venues, params: { capacity: 100 })).to be false
    end
  end

  describe "#find_tool_calls" do
    let(:response) do
      described_class.new(
        text:       "Done",
        tool_calls: [
          RSpec::Agents::ToolCall.new(name: :search, arguments: { q: "a" }),
          RSpec::Agents::ToolCall.new(name: :search, arguments: { q: "b" }),
          RSpec::Agents::ToolCall.new(name: :filter, arguments: {})
        ]
      )
    end

    it "returns all matching tool calls" do
      results = response.find_tool_calls(:search)
      expect(results.length).to eq(2)
      expect(results.map { |tc| tc.argument(:q) }).to eq(["a", "b"])
    end

    it "returns empty array when no matches" do
      expect(response.find_tool_calls(:missing)).to eq([])
    end

    it "filters by params" do
      results = response.find_tool_calls(:search, params: { q: "a" })
      expect(results.length).to eq(1)
    end
  end

  describe "#tool_call" do
    let(:response) do
      described_class.new(
        text:       "Done",
        tool_calls: [RSpec::Agents::ToolCall.new(name: :search, arguments: { q: "test" })]
      )
    end

    it "returns first matching tool call" do
      tc = response.tool_call(:search)
      expect(tc).to be_a(RSpec::Agents::ToolCall)
      expect(tc.name).to eq(:search)
    end

    it "returns nil when no match" do
      expect(response.tool_call(:missing)).to be_nil
    end
  end

  describe "#empty?" do
    it "returns true when text is nil" do
      response = described_class.new(text: nil)
      expect(response.empty?).to be true
    end

    it "returns true when text is empty string" do
      response = described_class.new(text: "")
      expect(response.empty?).to be true
    end

    it "returns false when text has content" do
      response = described_class.new(text: "Hello")
      expect(response.empty?).to be false
    end
  end

  describe "#length" do
    it "returns text length" do
      response = described_class.new(text: "Hello")
      expect(response.length).to eq(5)
    end

    it "returns 0 for nil text" do
      response = described_class.new(text: nil)
      expect(response.length).to eq(0)
    end
  end

  describe "#match?" do
    let(:response) { described_class.new(text: "Here are some venues in Stuttgart") }

    it "returns true when pattern matches" do
      expect(response.match?(/stuttgart/i)).to be true
    end

    it "returns false when pattern does not match" do
      expect(response.match?(/berlin/i)).to be false
    end
  end

  describe "#include?" do
    let(:response) { described_class.new(text: "Here are some venues") }

    it "returns true when substring present" do
      expect(response.include?("venues")).to be true
    end

    it "returns false when substring absent" do
      expect(response.include?("hotels")).to be false
    end
  end

  describe "#to_s" do
    it "returns text content" do
      response = described_class.new(text: "Hello!")
      expect(response.to_s).to eq("Hello!")
    end

    it "returns empty string for nil text" do
      response = described_class.new(text: nil)
      expect(response.to_s).to eq("")
    end
  end
end
