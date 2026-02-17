require "spec_helper"
require "rspec/agents"
require "stringio"

RSpec.describe RSpec::Agents::Observers::TerminalObserver do
  let(:output) { StringIO.new }
  let(:event_bus) { RSpec::Agents::EventBus.new }
  let(:time) { Time.now }
  let(:example_id) { "test123" }

  subject(:observer) do
    described_class.new(output: output, color: false, indent: 2, event_bus: event_bus)
  end

  def output_lines
    output.string.lines.map(&:chomp)
  end

  # Helper to send first user message (which starts conversation display)
  def start_conversation(source: :script)
    observer.on_user_message(
      RSpec::Agents::Events::UserMessage.new(
        example_id:  example_id,
        turn_number: 1,
        text:        "Initial message",
        source:      source,
        time:        time
      )
    )
  end

  describe "#on_simulation_started" do
    it "displays simulation started with goal" do
      event = RSpec::Agents::Events::SimulationStarted.new(
        example_id: example_id,
        goal:       "Book a venue for 50 people in Stuttgart",
        max_turns:  15,
        time:       time
      )

      observer.on_simulation_started(event)

      expect(output.string).to include("Simulation started")
      expect(output.string).to include("Book a venue for 50 people")
      expect(output.string).to include("\u250c") # box drawing corner
    end

    it "sets current_example_id for subsequent events" do
      simulation_event = RSpec::Agents::Events::SimulationStarted.new(
        example_id: example_id,
        goal:       "Test goal",
        max_turns:  10,
        time:       time
      )
      observer.on_simulation_started(simulation_event)

      # Clear output
      output.truncate(0)
      output.rewind

      # User message should now be displayed (same example_id)
      user_event = RSpec::Agents::Events::UserMessage.new(
        example_id:  example_id,
        turn_number: 1,
        text:        "Hello",
        source:      :simulator,
        time:        time
      )
      observer.on_user_message(user_event)

      # Should NOT show "Conversation started" since SimulationStarted already set context
      expect(output.string).not_to include("Conversation started")
      expect(output.string).to include("User:")
      expect(output.string).to include("Hello")
    end
  end

  describe "#on_simulation_ended" do
    before do
      # Start a simulation first
      observer.on_simulation_started(
        RSpec::Agents::Events::SimulationStarted.new(
          example_id: example_id,
          goal:       "Test goal",
          max_turns:  10,
          time:       time
        )
      )
    end

    it "displays simulation ended with turn count and reason" do
      event = RSpec::Agents::Events::SimulationEnded.new(
        example_id:         example_id,
        turn_count:         5,
        termination_reason: :stop_condition,
        time:               time
      )

      observer.on_simulation_ended(event)

      expect(output.string).to include("Simulation ended")
      expect(output.string).to include("5 turns")
      expect(output.string).to include("stop_condition")
      expect(output.string).to include("\u2514") # box drawing corner
    end

    it "shows max_turns termination reason" do
      event = RSpec::Agents::Events::SimulationEnded.new(
        example_id:         example_id,
        turn_count:         15,
        termination_reason: :max_turns,
        time:               time
      )

      observer.on_simulation_ended(event)

      expect(output.string).to include("max_turns")
    end
  end

  describe "#on_user_message" do
    it "displays conversation started message on first user message" do
      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  example_id,
        turn_number: 1,
        text:        "Hello, I need help",
        source:      :script,
        time:        time
      )

      observer.on_user_message(event)

      expect(output.string).to include("Conversation started (script)")
      expect(output.string).to include("\u250c") # box drawing corner
    end

    it "shows simulator mode when source is simulator" do
      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  example_id,
        turn_number: 1,
        text:        "Hello",
        source:      :simulator,
        time:        time
      )

      observer.on_user_message(event)

      expect(output.string).to include("Conversation started (simulator)")
    end

    it "displays user message with label" do
      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  example_id,
        turn_number: 1,
        text:        "Hello, I need help",
        source:      :script,
        time:        time
      )

      observer.on_user_message(event)

      expect(output.string).to include("User:")
      expect(output.string).to include("Hello, I need help")
      expect(output.string).to include("\u2502") # box drawing vertical line
    end

    it "switches to new example when different example_id message arrives" do
      # Send first message with example_id
      start_conversation

      # Clear output to focus on next message
      output.truncate(0)
      output.rewind

      # Message from different example starts a new conversation
      user_event = RSpec::Agents::Events::UserMessage.new(
        example_id:  "different_id",
        turn_number: 1,
        text:        "New example message",
        source:      :script,
        time:        time
      )
      observer.on_user_message(user_event)

      expect(output.string).to include("Conversation started")
      expect(output.string).to include("New example message")
    end

    it "truncates long messages" do
      long_text = "A" * 100

      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  example_id,
        turn_number: 1,
        text:        long_text,
        source:      :script,
        time:        time
      )

      observer.on_user_message(event)

      expect(output.string).to include("...")
      expect(output.string).not_to include("A" * 100)
    end

    it "does not show conversation started for subsequent messages" do
      # First message
      start_conversation

      # Clear and send second message
      output.truncate(0)
      output.rewind

      second_event = RSpec::Agents::Events::UserMessage.new(
        example_id:  example_id,
        turn_number: 2,
        text:        "Follow up message",
        source:      :script,
        time:        time
      )

      observer.on_user_message(second_event)

      expect(output.string).not_to include("Conversation started")
      expect(output.string).to include("Follow up message")
    end

    it "normalizes whitespace in messages" do
      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  example_id,
        turn_number: 1,
        text:        "Hello\n\nWorld\t\tTest",
        source:      :script,
        time:        time
      )

      observer.on_user_message(event)

      expect(output.string).to include("Hello World Test")
    end
  end

  describe "#on_agent_response" do
    before { start_conversation }

    it "displays agent response with label" do
      event = RSpec::Agents::Events::AgentResponse.new(
        example_id:  example_id,
        turn_number: 1,
        text:        "How can I help you?",
        tool_calls:  [],
        metadata:    {},
        time:        time
      )

      observer.on_agent_response(event)

      expect(output.string).to include("Agent:")
      expect(output.string).to include("How can I help you?")
    end

    it "shows tool call count when tools are used" do
      event = RSpec::Agents::Events::AgentResponse.new(
        example_id:  example_id,
        turn_number: 1,
        text:        "Found some results",
        tool_calls:  [{ name: :search }, { name: :filter }],
        metadata:    {},
        time:        time
      )

      observer.on_agent_response(event)

      expect(output.string).to include("[2 tool(s)]")
    end

    it "does not show tool info when no tools used" do
      event = RSpec::Agents::Events::AgentResponse.new(
        example_id:  example_id,
        turn_number: 1,
        text:        "Hello!",
        tool_calls:  [],
        metadata:    {},
        time:        time
      )

      observer.on_agent_response(event)

      expect(output.string).not_to include("tool")
    end
  end

  describe "#on_topic_changed" do
    before { start_conversation }

    it "displays topic transition" do
      event = RSpec::Agents::Events::TopicChanged.new(
        example_id:  example_id,
        turn_number: 2,
        from_topic:  :greeting,
        to_topic:    :gathering_details,
        trigger:     :classification,
        time:        time
      )

      observer.on_topic_changed(event)

      expect(output.string).to include("Topic:")
      expect(output.string).to include("greeting")
      expect(output.string).to include("gathering_details")
      expect(output.string).to include("->")
    end

    it "skips initial topic set (nil from_topic)" do
      event = RSpec::Agents::Events::TopicChanged.new(
        example_id:  example_id,
        turn_number: 0,
        from_topic:  nil,
        to_topic:    :greeting,
        trigger:     :initial,
        time:        time
      )

      observer.on_topic_changed(event)

      expect(output.string).not_to include("Topic:")
    end
  end

  describe "color support" do
    it "applies colors when enabled" do
      colored_observer = described_class.new(
        output:    output,
        color:     true,
        indent:    2,
        event_bus: event_bus
      )

      colored_observer.on_user_message(
        RSpec::Agents::Events::UserMessage.new(
          example_id:  example_id,
          turn_number: 1,
          text:        "Hello",
          source:      :script,
          time:        time
        )
      )

      # Should contain ANSI escape codes
      expect(output.string).to include("\e[")
    end

    it "does not apply colors when disabled" do
      observer.on_user_message(
        RSpec::Agents::Events::UserMessage.new(
          example_id:  example_id,
          turn_number: 1,
          text:        "Hello",
          source:      :script,
          time:        time
        )
      )

      # Should not contain ANSI escape codes
      expect(output.string).not_to include("\e[")
    end
  end

  describe "indentation" do
    it "uses the configured indent level" do
      observer_indent_4 = described_class.new(
        output:    output,
        color:     false,
        indent:    4,
        event_bus: event_bus
      )

      observer_indent_4.on_user_message(
        RSpec::Agents::Events::UserMessage.new(
          example_id:  example_id,
          turn_number: 1,
          text:        "Hello",
          source:      :script,
          time:        time
        )
      )

      # 4 * 2 spaces = 8 spaces of indentation
      expect(output.string).to include("        \u250c")
    end
  end

  describe "integration with EventBus" do
    it "receives events published to the event bus" do
      # Create the observer first (which registers with event_bus)
      observer

      event_bus.publish(
        RSpec::Agents::Events::UserMessage.new(
          example_id:  example_id,
          turn_number: 1,
          text:        "Hello from EventBus",
          source:      :script,
          time:        time
        )
      )

      expect(output.string).to include("Conversation started")
      expect(output.string).to include("Hello from EventBus")
    end
  end
end
