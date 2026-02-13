require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::EventBus do
  # Use a fresh instance for each test instead of the singleton
  let(:event_bus) do
    # Clear singleton state before each test
    described_class.instance.clear!
    described_class.instance
  end

  describe "#subscribe and #publish" do
    it "delivers events to global subscribers" do
      received = []
      event_bus.subscribe { |e| received << e }

      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello",
        source:      :script,
        time:        Time.now
      )
      event_bus.publish(event)

      expect(received).to eq([event])
    end

    it "delivers events to type-specific subscribers" do
      user_messages = []
      agent_responses = []

      event_bus.subscribe(RSpec::Agents::Events::UserMessage) { |e| user_messages << e }
      event_bus.subscribe(RSpec::Agents::Events::AgentResponse) { |e| agent_responses << e }

      user_event = RSpec::Agents::Events::UserMessage.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello",
        source:      :script,
        time:        Time.now
      )
      agent_event = RSpec::Agents::Events::AgentResponse.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hi there!",
        tool_calls:  [],
        metadata:    {},
        time:        Time.now
      )

      event_bus.publish(user_event)
      event_bus.publish(agent_event)

      expect(user_messages).to eq([user_event])
      expect(agent_responses).to eq([agent_event])
    end

    it "delivers events to both global and type-specific subscribers" do
      all_events = []
      user_messages = []

      event_bus.subscribe { |e| all_events << e }
      event_bus.subscribe(RSpec::Agents::Events::UserMessage) { |e| user_messages << e }

      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello",
        source:      :script,
        time:        Time.now
      )
      event_bus.publish(event)

      expect(all_events).to eq([event])
      expect(user_messages).to eq([event])
    end

    it "ignores nil events" do
      received = []
      event_bus.subscribe { |e| received << e }

      event_bus.publish(nil)

      expect(received).to be_empty
    end

    it "returns self from subscribe for chaining" do
      result = event_bus.subscribe { |_| }
      expect(result).to eq(event_bus)
    end
  end

  describe "error isolation" do
    it "catches and logs errors from observers without propagating" do
      event_bus.subscribe { raise "Observer error!" }

      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello",
        source:      :script,
        time:        Time.now
      )

      expect { event_bus.publish(event) }.not_to raise_error
    end

    it "continues delivering to other subscribers after an error" do
      received = []

      event_bus.subscribe { raise "First subscriber error!" }
      event_bus.subscribe { |e| received << e }

      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello",
        source:      :script,
        time:        Time.now
      )
      event_bus.publish(event)

      expect(received).to eq([event])
    end
  end

  describe "#add_observer" do
    it "registers an observer object and calls on_* methods" do
      observer = Class.new do
        attr_reader :user_messages, :agent_responses

        def initialize
          @user_messages = []
          @agent_responses = []
        end

        def on_user_message(event)
          @user_messages << event
        end

        def on_agent_response(event)
          @agent_responses << event
        end
      end.new

      event_bus.add_observer(observer)

      user_event = RSpec::Agents::Events::UserMessage.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello",
        source:      :script,
        time:        Time.now
      )
      agent_event = RSpec::Agents::Events::AgentResponse.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hi!",
        tool_calls:  [],
        metadata:    {},
        time:        Time.now
      )

      event_bus.publish(user_event)
      event_bus.publish(agent_event)

      expect(observer.user_messages).to eq([user_event])
      expect(observer.agent_responses).to eq([agent_event])
    end

    it "ignores events for which the observer has no handler" do
      observer = Class.new do
        attr_reader :user_messages

        def initialize
          @user_messages = []
        end

        def on_user_message(event)
          @user_messages << event
        end
        # No on_agent_response method
      end.new

      event_bus.add_observer(observer)

      agent_event = RSpec::Agents::Events::AgentResponse.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hi!",
        tool_calls:  [],
        metadata:    {},
        time:        Time.now
      )

      expect { event_bus.publish(agent_event) }.not_to raise_error
    end
  end

  describe "#clear!" do
    it "removes all subscriptions" do
      received = []
      event_bus.subscribe { |e| received << e }

      event_bus.clear!

      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello",
        source:      :script,
        time:        Time.now
      )
      event_bus.publish(event)

      expect(received).to be_empty
    end
  end
end
