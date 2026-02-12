require "spec_helper"

RSpec.describe RSpec::Agents::Message do
  describe "#initialize" do
    it "creates a message with required parameters" do
      message = described_class.new(role: :user, content: "Hello")

      expect(message.role).to eq(:user)
      expect(message.content).to eq("Hello")
    end

    it "converts string role to symbol" do
      message = described_class.new(role: "user", content: "Hello")

      expect(message.role).to eq(:user)
    end

    it "sets timestamp to current time by default" do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      message = described_class.new(role: :user, content: "Hello")

      expect(message.timestamp).to eq(freeze_time)
    end

    it "accepts custom timestamp" do
      custom_time = Time.new(2024, 1, 1, 12, 0, 0)
      message = described_class.new(role: :user, content: "Hello", timestamp: custom_time)

      expect(message.timestamp).to eq(custom_time)
    end

    it "initializes with empty tool_calls array by default" do
      message = described_class.new(role: :user, content: "Hello")

      expect(message.tool_calls).to eq([])
    end

    it "accepts tool_calls parameter" do
      tool_call = RSpec::Agents::ToolCall.new(name: :search, arguments: { query: "test" })
      message = described_class.new(role: :agent, content: "Searching...", tool_calls: [tool_call])

      expect(message.tool_calls).to eq([tool_call])
    end

    it "accepts metadata as hash" do
      message = described_class.new(role: :user, content: "Hello", metadata: { key: "value" })

      expect(message.metadata[:key]).to eq("value")
    end

    it "accepts metadata as Metadata object" do
      metadata = RSpec::Agents::Metadata.new({ key: "value" })
      message = described_class.new(role: :user, content: "Hello", metadata: metadata)

      expect(message.metadata).to eq(metadata)
    end

    it "creates empty Metadata when metadata is nil" do
      message = described_class.new(role: :user, content: "Hello", metadata: nil)

      expect(message.metadata).to be_a(RSpec::Agents::Metadata)
    end
  end

  describe "#user?" do
    it "returns true for user messages" do
      message = described_class.new(role: :user, content: "Hello")

      expect(message.user?).to be true
    end

    it "returns false for agent messages" do
      message = described_class.new(role: :agent, content: "Hi there")

      expect(message.user?).to be false
    end
  end

  describe "#agent?" do
    it "returns true for agent messages" do
      message = described_class.new(role: :agent, content: "Hello")

      expect(message.agent?).to be true
    end

    it "returns false for user messages" do
      message = described_class.new(role: :user, content: "Hi there")

      expect(message.agent?).to be false
    end
  end

  describe "#has_tool_call?" do
    let(:search_tool) { RSpec::Agents::ToolCall.new(name: :search, arguments: {}) }
    let(:filter_tool) { RSpec::Agents::ToolCall.new(name: :filter, arguments: {}) }
    let(:message) do
      described_class.new(
        role:       :agent,
        content:    "Processing",
        tool_calls: [search_tool, filter_tool]
      )
    end

    it "returns true when message contains the specified tool call" do
      expect(message.has_tool_call?(:search)).to be true
      expect(message.has_tool_call?(:filter)).to be true
    end

    it "accepts tool name as string" do
      expect(message.has_tool_call?("search")).to be true
    end

    it "returns false when message does not contain the tool call" do
      expect(message.has_tool_call?(:unknown)).to be false
    end

    it "returns false for messages with no tool calls" do
      msg = described_class.new(role: :user, content: "Hello")

      expect(msg.has_tool_call?(:search)).to be false
    end
  end

  describe "#[]" do
    let(:tool_call) { RSpec::Agents::ToolCall.new(name: :search, arguments: {}) }
    let(:timestamp) { Time.now }
    let(:metadata) { RSpec::Agents::Metadata.new({ key: "value" }) }
    let(:message) do
      described_class.new(
        role:       :agent,
        content:    "Hello",
        timestamp:  timestamp,
        tool_calls: [tool_call],
        metadata:   metadata
      )
    end

    it "provides hash-style access to role" do
      expect(message[:role]).to eq(:agent)
      expect(message["role"]).to eq(:agent)
    end

    it "provides hash-style access to content" do
      expect(message[:content]).to eq("Hello")
      expect(message["content"]).to eq("Hello")
    end

    it "provides hash-style access to timestamp" do
      expect(message[:timestamp]).to eq(timestamp)
      expect(message["timestamp"]).to eq(timestamp)
    end

    it "provides hash-style access to tool_calls" do
      expect(message[:tool_calls]).to eq([tool_call])
      expect(message["tool_calls"]).to eq([tool_call])
    end

    it "provides hash-style access to metadata" do
      expect(message[:metadata]).to eq(metadata)
      expect(message["metadata"]).to eq(metadata)
    end

    it "returns nil for unknown keys" do
      expect(message[:unknown]).to be_nil
      expect(message["unknown"]).to be_nil
    end
  end

  describe "#to_h" do
    let(:tool_call) { RSpec::Agents::ToolCall.new(name: :search, arguments: { query: "test" }) }
    let(:timestamp) { Time.new(2024, 1, 1, 12, 0, 0) }
    let(:message) do
      described_class.new(
        role:       :user,
        content:    "Search for something",
        timestamp:  timestamp,
        tool_calls: [tool_call],
        metadata:   { key: "value" }
      )
    end

    it "serializes to hash" do
      hash = message.to_h

      expect(hash).to be_a(Hash)
      expect(hash).to have_key(:role)
      expect(hash).to have_key(:content)
      expect(hash).to have_key(:timestamp)
      expect(hash).to have_key(:tool_calls)
      expect(hash).to have_key(:metadata)
    end

    it "includes role" do
      hash = message.to_h

      expect(hash[:role]).to eq(:user)
    end

    it "includes content" do
      hash = message.to_h

      expect(hash[:content]).to eq("Search for something")
    end

    it "includes timestamp" do
      hash = message.to_h

      expect(hash[:timestamp]).to eq(timestamp)
    end

    it "serializes tool_calls" do
      hash = message.to_h

      expect(hash[:tool_calls]).to be_an(Array)
      expect(hash[:tool_calls].first).to be_a(Hash)
    end

    it "serializes metadata" do
      hash = message.to_h

      expect(hash[:metadata]).to be_a(Hash)
      expect(hash[:metadata][:key]).to eq("value")
    end

    it "handles tool_calls without to_h method" do
      plain_tool = { name: :search, arguments: {} }
      msg = described_class.new(role: :agent, content: "Test", tool_calls: [plain_tool])

      hash = msg.to_h

      expect(hash[:tool_calls]).to eq([plain_tool])
    end

    it "wraps plain hash metadata" do
      msg = described_class.new(role: :agent, content: "Test", metadata: { plain: "metadata" })

      hash = msg.to_h

      expect(hash[:metadata]).to be_a(Hash)
      expect(hash[:metadata][:plain]).to eq("metadata")
    end
  end

  describe "#inspect" do
    it "includes class name and role" do
      message = described_class.new(role: :user, content: "Hello")

      inspection = message.inspect

      expect(inspection).to include("Message")
      expect(inspection).to include("role=user")
    end

    it "includes truncated content" do
      message = described_class.new(role: :user, content: "Hello world")

      inspection = message.inspect

      expect(inspection).to include("Hello world")
    end

    it "truncates long content" do
      long_content = "a" * 100
      message = described_class.new(role: :user, content: long_content)

      inspection = message.inspect

      expect(inspection.length).to be < long_content.length + 50
    end

    it "includes tool call count when present" do
      tool_call = RSpec::Agents::ToolCall.new(name: :search, arguments: {})
      message = described_class.new(role: :agent, content: "Test", tool_calls: [tool_call, tool_call])

      inspection = message.inspect

      expect(inspection).to include("tool_calls=2")
    end

    it "omits tool call info when no tools" do
      message = described_class.new(role: :user, content: "Test")

      inspection = message.inspect

      expect(inspection).not_to include("tool_calls")
    end
  end

  describe "message content variations" do
    it "handles empty content" do
      message = described_class.new(role: :user, content: "")

      expect(message.content).to eq("")
    end

    it "handles multiline content" do
      content = "Line 1\nLine 2\nLine 3"
      message = described_class.new(role: :user, content: content)

      expect(message.content).to eq(content)
    end

    it "handles special characters in content" do
      content = "Hello! How are you? I'm fine. #test @user $100"
      message = described_class.new(role: :user, content: content)

      expect(message.content).to eq(content)
    end

    it "handles unicode content" do
      content = "Hello 你好 مرحبا שלום"
      message = described_class.new(role: :user, content: content)

      expect(message.content).to eq(content)
    end
  end

  describe "role variations" do
    it "accepts :user role" do
      message = described_class.new(role: :user, content: "Test")

      expect(message.role).to eq(:user)
      expect(message.user?).to be true
      expect(message.agent?).to be false
    end

    it "accepts :agent role" do
      message = described_class.new(role: :agent, content: "Test")

      expect(message.role).to eq(:agent)
      expect(message.agent?).to be true
      expect(message.user?).to be false
    end

    it "converts 'user' string to :user symbol" do
      message = described_class.new(role: "user", content: "Test")

      expect(message.role).to eq(:user)
    end

    it "converts 'agent' string to :agent symbol" do
      message = described_class.new(role: "agent", content: "Test")

      expect(message.role).to eq(:agent)
    end
  end

  describe "metadata handling" do
    it "wraps hash metadata in Metadata object" do
      message = described_class.new(role: :user, content: "Test", metadata: { key: "value" })

      expect(message.metadata).to be_a(RSpec::Agents::Metadata)
      expect(message.metadata[:key]).to eq("value")
    end

    it "accepts Metadata object directly" do
      metadata = RSpec::Agents::Metadata.new({ key: "value" })
      message = described_class.new(role: :user, content: "Test", metadata: metadata)

      expect(message.metadata).to be(metadata)
    end

    it "creates empty Metadata when nil" do
      message = described_class.new(role: :user, content: "Test", metadata: nil)

      expect(message.metadata).to be_a(RSpec::Agents::Metadata)
    end

    it "allows access to metadata values" do
      message = described_class.new(
        role:     :user,
        content:  "Test",
        metadata: { latency: 100, model: "gpt-4" }
      )

      expect(message.metadata[:latency]).to eq(100)
      expect(message.metadata[:model]).to eq("gpt-4")
    end
  end

  describe "tool calls" do
    it "stores multiple tool calls" do
      tools = [
        RSpec::Agents::ToolCall.new(name: :search, arguments: {}),
        RSpec::Agents::ToolCall.new(name: :filter, arguments: {}),
        RSpec::Agents::ToolCall.new(name: :sort, arguments: {})
      ]
      message = described_class.new(role: :agent, content: "Processing", tool_calls: tools)

      expect(message.tool_calls.size).to eq(3)
    end

    it "provides access to tool call details" do
      tool = RSpec::Agents::ToolCall.new(name: :search, arguments: { query: "test", limit: 10 })
      message = described_class.new(role: :agent, content: "Searching", tool_calls: [tool])

      expect(message.tool_calls.first.name).to eq(:search)
      expect(message.tool_calls.first.arguments[:query]).to eq("test")
    end
  end

  describe "immutability" do
    it "has read-only attributes" do
      message = described_class.new(role: :user, content: "Test")

      expect { message.role = :agent }.to raise_error(NoMethodError)
      expect { message.content = "Changed" }.to raise_error(NoMethodError)
      expect { message.timestamp = Time.now }.to raise_error(NoMethodError)
    end

    it "allows reading all attributes" do
      message = described_class.new(
        role:     :user,
        content:  "Test",
        metadata: { key: "value" }
      )

      expect { message.role }.not_to raise_error
      expect { message.content }.not_to raise_error
      expect { message.timestamp }.not_to raise_error
      expect { message.tool_calls }.not_to raise_error
      expect { message.metadata }.not_to raise_error
    end
  end
end
