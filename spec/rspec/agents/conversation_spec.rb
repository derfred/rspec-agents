require "spec_helper"

RSpec.describe RSpec::Agents::Conversation do
  let(:event_bus) { instance_double(RSpec::Agents::EventBus, publish: nil) }
  let(:conversation) { described_class.new(event_bus: event_bus) }
  let(:agent_response) do
    RSpec::Agents::AgentResponse.new(
      text:       "Hello! How can I help you?",
      tool_calls: [],
      metadata:   {}
    )
  end

  describe "#initialize" do
    it "initializes with empty messages and turns" do
      expect(conversation.messages).to be_empty
      expect(conversation.turns).to be_empty
      expect(conversation.topic_history).to be_empty
    end

    it "accepts an optional event bus" do
      conv = described_class.new(event_bus: event_bus)
      expect(conv).to be_a(described_class)
    end

    it "works without an event bus" do
      conv = described_class.new
      expect(conv.messages).to be_empty
    end
  end

  describe "#add_user_message" do
    it "adds a user message to the conversation" do
      message = conversation.add_user_message("Hello")

      expect(conversation.messages.size).to eq(1)
      expect(message).to be_a(RSpec::Agents::Message)
      expect(message.role).to eq(:user)
      expect(message.content).to eq("Hello")
    end

    it "accepts metadata" do
      message = conversation.add_user_message("Hello", metadata: { key: "value" })

      expect(message.metadata[:key]).to eq("value")
    end

    it "accepts source parameter" do
      message = conversation.add_user_message("Hello", source: :simulator)

      expect(message).to be_a(RSpec::Agents::Message)
    end

    it "emits UserMessage event when event bus is present" do
      expect(event_bus).to receive(:publish).with(
        an_instance_of(RSpec::Agents::Events::UserMessage)
      )

      conversation.add_user_message("Hello", source: :script)
    end

    it "returns the created message" do
      result = conversation.add_user_message("Test")

      expect(result).to be_a(RSpec::Agents::Message)
      expect(result.content).to eq("Test")
    end
  end

  describe "#add_agent_response" do
    before do
      conversation.add_user_message("Hello")
    end

    it "adds an agent message to the conversation" do
      conversation.add_agent_response(agent_response)

      expect(conversation.messages.size).to eq(2)
      expect(conversation.messages.last.role).to eq(:agent)
    end

    it "creates a turn pairing user message with agent response" do
      conversation.add_agent_response(agent_response)

      expect(conversation.turns.size).to eq(1)
      expect(conversation.turns.first).to be_a(RSpec::Agents::Turn)
      expect(conversation.turns.first.user_message).to eq("Hello")
      expect(conversation.turns.first.agent_response).to eq(agent_response)
    end

    it "emits AgentResponse event when event bus is present" do
      expect(event_bus).to receive(:publish).with(
        an_instance_of(RSpec::Agents::Events::AgentResponse)
      )

      conversation.add_agent_response(agent_response)
    end

    it "increments topic turn count when topic is set" do
      conversation.set_topic(:greeting)
      conversation.add_agent_response(agent_response)

      expect(conversation.turns_in_topic(:greeting)).to eq(1)
    end

    it "adds turn to topic history when topic is set" do
      conversation.set_topic(:greeting)
      conversation.add_agent_response(agent_response)

      expect(conversation.turns_for_topic(:greeting).size).to eq(1)
    end

    it "returns the created turn" do
      turn = conversation.add_agent_response(agent_response)

      expect(turn).to be_a(RSpec::Agents::Turn)
      expect(turn.agent_response).to eq(agent_response)
    end

    it "handles tool calls in response" do
      response_with_tools = RSpec::Agents::AgentResponse.new(
        text:       "Let me search for that",
        tool_calls: [
          RSpec::Agents::ToolCall.new(name: :search, arguments: { query: "test" })
        ],
        metadata:   {}
      )

      conversation.add_agent_response(response_with_tools)

      expect(conversation.messages.last.tool_calls.size).to eq(1)
    end
  end

  describe "#set_topic" do
    it "sets the current topic" do
      conversation.set_topic(:greeting)

      expect(conversation.current_topic).to eq(:greeting)
    end

    it "adds topic to history" do
      conversation.set_topic(:greeting)

      expect(conversation.topic_history.size).to eq(1)
      expect(conversation.topic_history.first[:topic]).to eq(:greeting)
    end

    it "emits TopicChanged event when event bus is present" do
      expect(event_bus).to receive(:publish).with(
        an_instance_of(RSpec::Agents::Events::TopicChanged)
      )

      conversation.set_topic(:greeting)
    end

    it "does not change topic if already set to same topic" do
      conversation.set_topic(:greeting)
      initial_history_size = conversation.topic_history.size

      conversation.set_topic(:greeting)

      expect(conversation.topic_history.size).to eq(initial_history_size)
    end

    it "tracks previous topic in event" do
      conversation.set_topic(:greeting)

      expect(event_bus).to receive(:publish).with(
        having_attributes(from_topic: :greeting, to_topic: :details)
      )

      conversation.set_topic(:details)
    end

    it "accepts trigger parameter" do
      expect(event_bus).to receive(:publish).with(
        having_attributes(trigger: :explicit)
      )

      conversation.set_topic(:greeting, trigger: :explicit)
    end
  end

  describe "#current_topic" do
    it "returns nil when no topic is set" do
      expect(conversation.current_topic).to be_nil
    end

    it "returns the current topic" do
      conversation.set_topic(:greeting)

      expect(conversation.current_topic).to eq(:greeting)
    end
  end

  describe "#turns_in_topic" do
    it "returns 0 for topics with no turns" do
      expect(conversation.turns_in_topic(:greeting)).to eq(0)
    end

    it "counts turns in a specific topic" do
      conversation.set_topic(:greeting)
      conversation.add_user_message("Hi")
      conversation.add_agent_response(agent_response)
      conversation.add_user_message("How are you?")
      conversation.add_agent_response(agent_response)

      expect(conversation.turns_in_topic(:greeting)).to eq(2)
    end

    it "tracks turns separately for different topics" do
      conversation.set_topic(:greeting)
      conversation.add_user_message("Hi")
      conversation.add_agent_response(agent_response)

      conversation.set_topic(:details)
      conversation.add_user_message("Tell me more")
      conversation.add_agent_response(agent_response)

      expect(conversation.turns_in_topic(:greeting)).to eq(1)
      expect(conversation.turns_in_topic(:details)).to eq(1)
    end
  end

  describe "#turns_for_topic" do
    it "returns empty array for topics with no turns" do
      expect(conversation.turns_for_topic(:greeting)).to eq([])
    end

    it "returns all turns for a specific topic" do
      conversation.set_topic(:greeting)
      conversation.add_user_message("Hi")
      turn1 = conversation.add_agent_response(agent_response)
      conversation.add_user_message("How are you?")
      turn2 = conversation.add_agent_response(agent_response)

      turns = conversation.turns_for_topic(:greeting)

      expect(turns.size).to eq(2)
      expect(turns).to include(turn1, turn2)
    end

    it "returns only turns for the specified topic" do
      conversation.set_topic(:greeting)
      conversation.add_user_message("Hi")
      greeting_turn = conversation.add_agent_response(agent_response)

      conversation.set_topic(:details)
      conversation.add_user_message("Tell me more")
      conversation.add_agent_response(agent_response)

      expect(conversation.turns_for_topic(:greeting)).to eq([greeting_turn])
    end
  end

  describe "tool call methods" do
    let(:search_tool) { RSpec::Agents::ToolCall.new(name: :search, arguments: { query: "test" }) }
    let(:filter_tool) { RSpec::Agents::ToolCall.new(name: :filter, arguments: { type: "active" }) }
    let(:response_with_tools) do
      RSpec::Agents::AgentResponse.new(
        text:       "Searching...",
        tool_calls: [search_tool, filter_tool],
        metadata:   {}
      )
    end

    before do
      conversation.add_user_message("Find something")
      conversation.add_agent_response(response_with_tools)
    end

    describe "#all_tool_calls" do
      it "returns all tool calls across all turns" do
        expect(conversation.all_tool_calls.size).to eq(2)
        expect(conversation.all_tool_calls).to include(search_tool, filter_tool)
      end

      it "returns empty array when no tool calls" do
        conv = described_class.new
        expect(conv.all_tool_calls).to eq([])
      end
    end

    describe "#has_tool_call?" do
      it "returns true when tool was called" do
        expect(conversation.has_tool_call?(:search)).to be true
        expect(conversation.has_tool_call?("search")).to be true
      end

      it "returns false when tool was not called" do
        expect(conversation.has_tool_call?(:unknown)).to be false
      end
    end

    describe "#called_tool?" do
      it "counts how many times a tool was called" do
        expect(conversation.called_tool?(:search)).to eq(1)
        expect(conversation.called_tool?(:filter)).to eq(1)
      end

      it "returns 0 for tools that were not called" do
        expect(conversation.called_tool?(:unknown)).to eq(0)
      end
    end

    describe "#find_tool_calls" do
      it "finds tool calls by name" do
        calls = conversation.find_tool_calls(:search)

        expect(calls.size).to eq(1)
        expect(calls.first.name).to eq(:search)
      end

      it "filters by parameters when provided" do
        calls = conversation.find_tool_calls(:search, params: { query: "test" })

        expect(calls.size).to eq(1)
      end

      it "returns empty array when no matches" do
        calls = conversation.find_tool_calls(:unknown)

        expect(calls).to eq([])
      end
    end
  end

  describe "#last_agent_response" do
    it "returns nil when no turns" do
      expect(conversation.last_agent_response).to be_nil
    end

    it "returns the last agent response" do
      conversation.add_user_message("Hello")
      conversation.add_agent_response(agent_response)

      expect(conversation.last_agent_response).to eq(agent_response)
    end
  end

  describe "#last_user_message" do
    it "returns nil when no messages" do
      expect(conversation.last_user_message).to be_nil
    end

    it "returns the last user message content" do
      conversation.add_user_message("First message")
      conversation.add_user_message("Second message")

      expect(conversation.last_user_message).to eq("Second message")
    end

    it "returns last user message even after agent response" do
      conversation.add_user_message("User message")
      conversation.add_agent_response(agent_response)

      expect(conversation.last_user_message).to eq("User message")
    end
  end

  describe "#last_turn" do
    it "returns nil when no turns" do
      expect(conversation.last_turn).to be_nil
    end

    it "returns the last turn" do
      conversation.add_user_message("Hello")
      turn = conversation.add_agent_response(agent_response)

      expect(conversation.last_turn).to eq(turn)
    end
  end

  describe "#turn_count" do
    it "returns 0 when no turns" do
      expect(conversation.turn_count).to eq(0)
    end

    it "counts the number of turns" do
      conversation.add_user_message("Hello")
      conversation.add_agent_response(agent_response)
      conversation.add_user_message("How are you?")
      conversation.add_agent_response(agent_response)

      expect(conversation.turn_count).to eq(2)
    end
  end

  describe "#empty?" do
    it "returns true when no messages" do
      expect(conversation.empty?).to be true
    end

    it "returns false when messages exist" do
      conversation.add_user_message("Hello")

      expect(conversation.empty?).to be false
    end
  end

  describe "#messages_for_agent" do
    it "returns messages in agent-compatible format" do
      conversation.add_user_message("Hello")
      conversation.add_agent_response(agent_response)

      messages = conversation.messages_for_agent

      expect(messages).to be_an(Array)
      expect(messages.size).to eq(2)
      expect(messages.first).to eq({ role: "user", content: "Hello" })
      expect(messages.last).to eq({ role: "agent", content: "Hello! How can I help you?" })
    end

    it "converts role symbols to strings" do
      conversation.add_user_message("Test")

      messages = conversation.messages_for_agent

      expect(messages.first[:role]).to be_a(String)
      expect(messages.first[:role]).to eq("user")
    end
  end

  describe "#reset!" do
    before do
      conversation.set_topic(:greeting)
      conversation.add_user_message("Hello")
      conversation.add_agent_response(agent_response)
    end

    it "clears all messages" do
      conversation.reset!

      expect(conversation.messages).to be_empty
    end

    it "clears all turns" do
      conversation.reset!

      expect(conversation.turns).to be_empty
    end

    it "clears topic history" do
      conversation.reset!

      expect(conversation.topic_history).to be_empty
    end

    it "resets current topic" do
      conversation.reset!

      expect(conversation.current_topic).to be_nil
    end

    it "resets turn counts per topic" do
      conversation.reset!

      expect(conversation.turns_in_topic(:greeting)).to eq(0)
    end
  end

  describe "#to_h" do
    before do
      conversation.set_topic(:greeting)
      conversation.add_user_message("Hello")
      conversation.add_agent_response(agent_response)
    end

    it "serializes to hash" do
      hash = conversation.to_h

      expect(hash).to be_a(Hash)
      expect(hash).to have_key(:messages)
      expect(hash).to have_key(:turns)
      expect(hash).to have_key(:topic_history)
      expect(hash).to have_key(:current_topic)
    end

    it "includes serialized messages" do
      hash = conversation.to_h

      expect(hash[:messages]).to be_an(Array)
      expect(hash[:messages].size).to eq(2)
    end

    it "includes serialized turns" do
      hash = conversation.to_h

      expect(hash[:turns]).to be_an(Array)
      expect(hash[:turns].size).to eq(1)
    end

    it "includes current topic" do
      hash = conversation.to_h

      expect(hash[:current_topic]).to eq(:greeting)
    end
  end

  describe "#inspect" do
    it "shows turn and message counts" do
      conversation.add_user_message("Hello")
      conversation.add_agent_response(agent_response)

      inspection = conversation.inspect

      expect(inspection).to include("turns=1")
      expect(inspection).to include("messages=2")
    end
  end

  describe "complex conversation flow" do
    it "handles multi-turn conversations with topic changes" do
      # Greeting phase
      conversation.set_topic(:greeting)
      conversation.add_user_message("Hi there")
      conversation.add_agent_response(agent_response)

      # Details phase
      conversation.set_topic(:details)
      conversation.add_user_message("Tell me about your features")
      conversation.add_agent_response(agent_response)
      conversation.add_user_message("What else can you do?")
      conversation.add_agent_response(agent_response)

      # Verify state
      expect(conversation.turn_count).to eq(3)
      expect(conversation.turns_in_topic(:greeting)).to eq(1)
      expect(conversation.turns_in_topic(:details)).to eq(2)
      expect(conversation.current_topic).to eq(:details)
      expect(conversation.topic_history.size).to eq(2)
    end

    it "maintains message order across topic changes" do
      conversation.set_topic(:greeting)
      conversation.add_user_message("First")
      conversation.add_agent_response(agent_response)

      conversation.set_topic(:details)
      conversation.add_user_message("Second")
      conversation.add_agent_response(agent_response)

      messages = conversation.messages_for_agent

      expect(messages[0][:content]).to eq("First")
      expect(messages[2][:content]).to eq("Second")
    end
  end

  describe "evaluation tracking" do
    describe "#record_evaluation" do
      it "records a soft evaluation" do
        result = conversation.record_evaluation(
          mode:        :soft,
          type:        :quality,
          description: "test",
          passed:      true
        )

        expect(result).to be_a(RSpec::Agents::EvaluationResult)
        expect(result.mode).to eq(:soft)
        expect(conversation.evaluation_results).to include(result)
      end

      it "records a hard evaluation" do
        result = conversation.record_evaluation(
          mode:            :hard,
          type:            :tool_call,
          description:     "call_tool(:search)",
          passed:          false,
          failure_message: "Not called"
        )

        expect(result.mode).to eq(:hard)
        expect(result.passed).to be false
        expect(result.failure_message).to eq("Not called")
      end

      it "adds turn_number and topic to metadata" do
        conversation.set_topic(:greeting)
        conversation.add_user_message("Hi")
        conversation.add_agent_response(agent_response)

        result = conversation.record_evaluation(
          mode:        :soft,
          type:        :quality,
          description: "test",
          passed:      true,
          metadata:    { custom: "data" }
        )

        expect(result.metadata[:turn_number]).to eq(1)
        expect(result.metadata[:topic]).to eq(:greeting)
        expect(result.metadata[:custom]).to eq("data")
      end
    end

    describe "#soft_evaluations" do
      it "returns only soft evaluations" do
        conversation.record_evaluation(mode: :soft, type: :quality, description: "soft1", passed: true)
        conversation.record_evaluation(mode: :hard, type: :quality, description: "hard1", passed: true)
        conversation.record_evaluation(mode: :soft, type: :quality, description: "soft2", passed: false)

        soft = conversation.soft_evaluations
        expect(soft.size).to eq(2)
        expect(soft.all?(&:soft?)).to be true
      end
    end

    describe "#hard_evaluations" do
      it "returns only hard evaluations" do
        conversation.record_evaluation(mode: :soft, type: :quality, description: "soft1", passed: true)
        conversation.record_evaluation(mode: :hard, type: :quality, description: "hard1", passed: true)
        conversation.record_evaluation(mode: :hard, type: :quality, description: "hard2", passed: false)

        hard = conversation.hard_evaluations
        expect(hard.size).to eq(2)
        expect(hard.all?(&:hard?)).to be true
      end
    end

    describe "#reset!" do
      it "clears evaluation results" do
        conversation.record_evaluation(mode: :soft, type: :quality, description: "test", passed: true)
        expect(conversation.evaluation_results).not_to be_empty

        conversation.reset!
        expect(conversation.evaluation_results).to be_empty
      end
    end

    describe "#to_h" do
      it "includes evaluation_results" do
        conversation.record_evaluation(mode: :soft, type: :quality, description: "test", passed: true)

        hash = conversation.to_h
        expect(hash[:evaluation_results]).to be_an(Array)
        expect(hash[:evaluation_results].first[:mode]).to eq(:soft)
      end
    end
  end
end
