require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::Agents::Base do
  describe ".build" do
    it "creates new instance with context" do
      context = { test_name: "my test", test_file: "spec/my_spec.rb" }
      agent = described_class.build(context)

      expect(agent).to be_a(described_class)
    end

    it "defaults context to empty hash" do
      agent = described_class.build
      expect(agent).to be_a(described_class)
    end
  end

  describe "#initialize" do
    it "stores context" do
      context = { test_name: "my test" }
      agent = described_class.new(context: context)

      # Access via protected method for testing
      expect(agent.send(:context)).to eq(context)
    end

    it "defaults context to empty hash" do
      agent = described_class.new
      expect(agent.send(:context)).to eq({})
    end
  end

  describe "#chat" do
    it "raises NotImplementedError" do
      agent = described_class.new
      messages = [{ role: "user", content: "Hello" }]

      expect {
        agent.chat(messages)
      }.to raise_error(NotImplementedError, /must implement #chat/)
    end

    it "accepts on_tool_call keyword argument" do
      agent = described_class.new
      messages = [{ role: "user", content: "Hello" }]

      expect {
        agent.chat(messages, on_tool_call: ->(tc) {})
      }.to raise_error(NotImplementedError)
    end
  end

  describe "#reset!" do
    it "is a no-op by default" do
      agent = described_class.new
      expect { agent.reset! }.not_to raise_error
    end
  end

  describe "#around" do
    it "calls the block by default (no-op wrapper)" do
      agent = described_class.new
      called = false

      agent.around { called = true }

      expect(called).to be true
    end

    it "returns the block result" do
      agent = described_class.new

      result = agent.around { 42 }

      expect(result).to eq(42)
    end
  end

  describe "#metadata" do
    it "returns empty Metadata by default" do
      agent = described_class.new
      expect(agent.metadata).to be_a(RSpec::Agents::Metadata)
      expect(agent.metadata.empty?).to be true
    end
  end

  describe "#normalize_messages" do
    let(:agent) { described_class.new }

    it "normalizes hash messages with symbol keys" do
      messages = [{ role: "user", content: "Hello" }]
      normalized = agent.send(:normalize_messages, messages)

      expect(normalized).to eq([{ role: "user", content: "Hello" }])
    end

    it "normalizes hash messages with string keys" do
      messages = [{ "role" => "user", "content" => "Hello" }]
      normalized = agent.send(:normalize_messages, messages)

      expect(normalized).to eq([{ role: "user", content: "Hello" }])
    end

    it "normalizes objects with role and content methods" do
      message = double("Message", role: "user", content: "Hello")
      normalized = agent.send(:normalize_messages, [message])

      expect(normalized).to eq([{ role: "user", content: "Hello" }])
    end
  end

  describe "custom implementation" do
    let(:test_agent_class) do
      Class.new(described_class) do
        attr_reader :chat_calls

        def initialize(context: {}, responses: [])
          super(context: context)
          @responses = responses
          @call_index = 0
          @chat_calls = []
        end

        def self.build(context = {})
          new(context: context, responses: [
            RSpec::Agents::AgentResponse.new(text: "Hello! How can I help?")
          ])
        end

        def chat(messages, on_tool_call: nil)
          @chat_calls << messages
          response = @responses[@call_index] || @responses.last
          @call_index += 1

          # Signal tool calls if callback provided
          response.tool_calls.each { |tc| on_tool_call&.call(tc) }

          response
        end

        def reset!
          @call_index = 0
          @chat_calls = []
        end

        def metadata
          RSpec::Agents::Metadata.new(agent_type: "test", call_count: @call_index)
        end
      end
    end

    it "can be subclassed with custom behavior" do
      agent = test_agent_class.build(test_name: "my test")

      response = agent.chat([{ role: "user", content: "Hi" }])

      expect(response).to be_a(RSpec::Agents::AgentResponse)
      expect(response.text).to eq("Hello! How can I help?")
      expect(agent.chat_calls.length).to eq(1)
    end

    it "supports reset" do
      agent = test_agent_class.build
      agent.chat([{ role: "user", content: "Hi" }])
      agent.chat([{ role: "user", content: "Hello" }])

      expect(agent.chat_calls.length).to eq(2)

      agent.reset!

      expect(agent.chat_calls.length).to eq(0)
    end

    it "provides metadata" do
      agent = test_agent_class.build
      agent.chat([{ role: "user", content: "Hi" }])

      expect(agent.metadata[:agent_type]).to eq("test")
      expect(agent.metadata[:call_count]).to eq(1)
    end

    it "invokes on_tool_call callback for each tool call" do
      agent_with_tools = Class.new(described_class) do
        def chat(messages, on_tool_call: nil)
          tool_calls = [
            RSpec::Agents::ToolCall.new(name: :search, arguments: { q: "test" }, result: { found: true })
          ]

          tool_calls.each { |tc| on_tool_call&.call(tc) }

          RSpec::Agents::AgentResponse.new(text: "Found results", tool_calls: tool_calls)
        end
      end.new

      signaled_calls = []

      agent_with_tools.chat([{ role: "user", content: "Hi" }], on_tool_call: ->(tc) { signaled_calls << tc })

      expect(signaled_calls.length).to eq(1)
      expect(signaled_calls.first.name).to eq(:search)
      expect(signaled_calls.first.result).to eq({ found: true })
    end
  end
end
