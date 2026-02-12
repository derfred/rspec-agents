require "spec_helper"
require "rspec/agents"

RSpec.describe "Conversation event emission" do
  let(:event_bus) do
    RSpec::Agents::EventBus.instance.tap(&:clear!)
  end
  let(:events) { [] }
  let(:example_id) { "test-example-123" }

  before do
    event_bus.subscribe { |e| events << e }
    Thread.current[:rspec_agents_example_id] = example_id
  end

  after do
    Thread.current[:rspec_agents_example_id] = nil
  end

  describe RSpec::Agents::Conversation do
    describe "#initialize" do
      it "does not emit any events on initialization" do
        RSpec::Agents::Conversation.new(event_bus: event_bus)

        expect(events).to be_empty
      end

      it "does not emit events when event_bus is nil" do
        RSpec::Agents::Conversation.new

        expect(events).to be_empty
      end

      it "captures example_id from Thread.current for later events" do
        Thread.current[:rspec_agents_example_id] = "custom-id"

        conversation = RSpec::Agents::Conversation.new(event_bus: event_bus)
        conversation.add_user_message("Hello", source: :script)

        expect(events.first.example_id).to eq("custom-id")
      end
    end

    describe "#add_user_message" do
      let(:conversation) do
        RSpec::Agents::Conversation.new(event_bus: event_bus)
      end

      it "emits UserMessage event" do
        conversation.add_user_message("Hello there", source: :script)

        expect(events.size).to eq(1)
        expect(events.first).to be_a(RSpec::Agents::Events::UserMessage)
        expect(events.first.text).to eq("Hello there")
        expect(events.first.source).to eq(:script)
        expect(events.first.turn_number).to eq(1)
        expect(events.first.example_id).to eq(example_id)
      end

      it "increments turn_number for subsequent messages" do
        conversation.add_user_message("First", source: :script)
        conversation.add_agent_response(
          RSpec::Agents::AgentResponse.new(text: "Response 1")
        )
        events.clear

        conversation.add_user_message("Second", source: :script)

        expect(events.first.turn_number).to eq(2)
      end

      it "preserves the source parameter" do
        conversation.add_user_message("From simulator", source: :simulator)

        expect(events.last.source).to eq(:simulator)
      end
    end

    describe "#add_agent_response" do
      let(:conversation) do
        RSpec::Agents::Conversation.new(event_bus: event_bus)
      end

      before do
        conversation.add_user_message("Hello", source: :script)
        events.clear
      end

      it "emits AgentResponse event" do
        response = RSpec::Agents::AgentResponse.new(
          text: "Hi! How can I help?"
        )
        conversation.add_agent_response(response)

        expect(events.size).to eq(1)
        expect(events.first).to be_a(RSpec::Agents::Events::AgentResponse)
        expect(events.first.text).to eq("Hi! How can I help?")
        expect(events.first.turn_number).to eq(1)
        expect(events.first.example_id).to eq(example_id)
      end

      it "includes tool_calls in the event" do
        tool_call = RSpec::Agents::ToolCall.new(
          name:      :search,
          arguments: { query: "venues" },
          result:    { results: [] }
        )
        response = RSpec::Agents::AgentResponse.new(
          text:       "Found results",
          tool_calls: [tool_call]
        )
        conversation.add_agent_response(response)

        expect(events.first.tool_calls.size).to eq(1)
        expect(events.first.tool_calls.first[:name]).to eq(:search)
      end

      it "handles responses without tool_calls" do
        response = RSpec::Agents::AgentResponse.new(text: "Hello!")
        conversation.add_agent_response(response)

        expect(events.first.tool_calls).to eq([])
      end
    end

    describe "#set_topic" do
      let(:conversation) do
        RSpec::Agents::Conversation.new(event_bus: event_bus)
      end

      it "emits TopicChanged event" do
        conversation.set_topic(:greeting, trigger: :initial)

        expect(events.size).to eq(1)
        expect(events.first).to be_a(RSpec::Agents::Events::TopicChanged)
        expect(events.first.from_topic).to be_nil
        expect(events.first.to_topic).to eq(:greeting)
        expect(events.first.trigger).to eq(:initial)
      end

      it "tracks topic transitions" do
        conversation.set_topic(:greeting, trigger: :initial)
        events.clear

        conversation.set_topic(:gathering_details, trigger: :classification)

        expect(events.first.from_topic).to eq(:greeting)
        expect(events.first.to_topic).to eq(:gathering_details)
      end

      it "does not emit event when topic unchanged" do
        conversation.set_topic(:greeting, trigger: :initial)
        events.clear

        conversation.set_topic(:greeting, trigger: :classification)

        expect(events).to be_empty
      end

      it "uses :unknown trigger when not specified" do
        conversation.set_topic(:greeting)

        expect(events.last.trigger).to eq(:unknown)
      end
    end

    describe "full conversation lifecycle" do
      it "emits events for complete conversation" do
        conversation = RSpec::Agents::Conversation.new(event_bus: event_bus)

        conversation.set_topic(:greeting, trigger: :initial)
        conversation.add_user_message("Hello", source: :script)
        conversation.add_agent_response(RSpec::Agents::AgentResponse.new(text: "Hi!"))
        conversation.set_topic(:gathering_details, trigger: :classification)
        conversation.add_user_message("I need help", source: :script)
        conversation.add_agent_response(RSpec::Agents::AgentResponse.new(text: "Sure!"))

        event_types = events.map { |e| e.class.name.split("::").last }

        expect(event_types).to eq([
          "TopicChanged",      # initial topic
          "UserMessage",
          "AgentResponse",
          "TopicChanged",      # topic transition
          "UserMessage",
          "AgentResponse"
        ])
      end
    end
  end
end
