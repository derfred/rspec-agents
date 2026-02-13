require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::Events do
  let(:time) { Time.now }

  describe RSpec::Agents::Events::UserMessage do
    it "creates an event with all required fields" do
      event = described_class.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello, I need help",
        source:      :script,
        time:        time
      )

      expect(event.example_id).to eq("abc123")
      expect(event.turn_number).to eq(1)
      expect(event.text).to eq("Hello, I need help")
      expect(event.source).to eq(:script)
      expect(event.time).to eq(time)
    end

    it "supports different source types" do
      script_event = described_class.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello",
        source:      :script,
        time:        time
      )

      simulator_event = described_class.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello",
        source:      :simulator,
        time:        time
      )

      expect(script_event.source).to eq(:script)
      expect(simulator_event.source).to eq(:simulator)
    end
  end

  describe RSpec::Agents::Events::AgentResponse do
    it "creates an event with all required fields" do
      tool_calls = [{ name: :search, arguments: { query: "venues" } }]

      event = described_class.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "I found some venues for you",
        tool_calls:  tool_calls,
        metadata:    {},
        time:        time
      )

      expect(event.example_id).to eq("abc123")
      expect(event.turn_number).to eq(1)
      expect(event.text).to eq("I found some venues for you")
      expect(event.tool_calls).to eq(tool_calls)
      expect(event.time).to eq(time)
    end

    it "handles empty tool_calls" do
      event = described_class.new(
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello!",
        tool_calls:  [],
        metadata:    {},
        time:        time
      )

      expect(event.tool_calls).to eq([])
    end
  end

  describe RSpec::Agents::Events::TopicChanged do
    it "creates an event with all required fields" do
      event = described_class.new(
        example_id:  "abc123",
        turn_number: 2,
        from_topic:  :greeting,
        to_topic:    :gathering_details,
        trigger:     :classification,
        time:        time
      )

      expect(event.example_id).to eq("abc123")
      expect(event.turn_number).to eq(2)
      expect(event.from_topic).to eq(:greeting)
      expect(event.to_topic).to eq(:gathering_details)
      expect(event.trigger).to eq(:classification)
      expect(event.time).to eq(time)
    end

    it "allows nil from_topic for initial topic" do
      event = described_class.new(
        example_id:  "abc123",
        turn_number: 0,
        from_topic:  nil,
        to_topic:    :greeting,
        trigger:     :initial,
        time:        time
      )

      expect(event.from_topic).to be_nil
      expect(event.to_topic).to eq(:greeting)
    end
  end

  # ==========================================================================
  # RSpec Lifecycle Events
  # ==========================================================================

  describe RSpec::Agents::Events::SuiteStarted do
    it "creates an event with all required fields" do
      event = described_class.new(
        example_count: 42,
        load_time:     1.5,
        seed:          12345,
        time:          time
      )

      expect(event.example_count).to eq(42)
      expect(event.load_time).to eq(1.5)
      expect(event.seed).to eq(12345)
      expect(event.time).to eq(time)
    end
  end

  describe RSpec::Agents::Events::GroupStarted do
    it "creates an event with all required fields" do
      event = described_class.new(
        description: "MyClass",
        file_path:   "spec/my_class_spec.rb",
        line_number: 5,
        time:        time
      )

      expect(event.description).to eq("MyClass")
      expect(event.file_path).to eq("spec/my_class_spec.rb")
      expect(event.line_number).to eq(5)
    end
  end

  describe RSpec::Agents::Events::ExampleStarted do
    it "creates an event with all required fields" do
      event = described_class.new(
        example_id:       "abc123",
        stable_id:        "stable_abc123",
        canonical_path:   "MyClass > does something",
        description:      "does something",
        full_description: "MyClass does something",
        location:         "spec/my_class_spec.rb:10",
        scenario:         nil,
        time:             time
      )

      expect(event.example_id).to eq("abc123")
      expect(event.stable_id).to eq("stable_abc123")
      expect(event.canonical_path).to eq("MyClass > does something")
      expect(event.description).to eq("does something")
      expect(event.full_description).to eq("MyClass does something")
      expect(event.location).to eq("spec/my_class_spec.rb:10")
      expect(event.scenario).to be_nil
    end
  end

  describe RSpec::Agents::Events::ExampleFailed do
    it "creates an event with all required fields" do
      event = described_class.new(
        example_id:       "abc123",
        stable_id:        "stable_abc123",
        description:      "fails",
        full_description: "MyClass fails",
        location:         "spec/my_class_spec.rb:15",
        duration:         0.5,
        message:          "Expected true, got false",
        backtrace:        ["spec/my_class_spec.rb:15"],
        time:             time
      )

      expect(event.example_id).to eq("abc123")
      expect(event.stable_id).to eq("stable_abc123")
      expect(event.message).to eq("Expected true, got false")
      expect(event.backtrace).to eq(["spec/my_class_spec.rb:15"])
      expect(event.location).to eq("spec/my_class_spec.rb:15")
      expect(event.duration).to eq(0.5)
    end
  end

  # ==========================================================================
  # Event Reconstruction (from_hash)
  # ==========================================================================

  describe ".from_hash" do
    it "reconstructs ExampleStarted from hash" do
      payload = {
        example_id:       "abc123",
        description:      "does something",
        full_description: "MyClass does something",
        location:         "spec/my_spec.rb:10",
        time:             time
      }

      event = described_class.from_hash("ExampleStarted", payload)

      expect(event).to be_a(RSpec::Agents::Events::ExampleStarted)
      expect(event.example_id).to eq("abc123")
      expect(event.description).to eq("does something")
    end

    it "reconstructs UserMessage from hash" do
      payload = {
        example_id:  "abc123",
        turn_number: 1,
        text:        "Hello",
        source:      :simulator,
        time:        time
      }

      event = described_class.from_hash("UserMessage", payload)

      expect(event).to be_a(RSpec::Agents::Events::UserMessage)
      expect(event.text).to eq("Hello")
    end

    it "handles string keys in payload" do
      payload = {
        "example_id"       => "abc123",
        "description"      => "test",
        "full_description" => "full test",
        "location"         => "spec/test.rb:1",
        "time"             => time
      }

      event = described_class.from_hash("ExampleStarted", payload)

      expect(event).to be_a(RSpec::Agents::Events::ExampleStarted)
      expect(event.example_id).to eq("abc123")
    end

    it "returns nil for unknown event types" do
      event = described_class.from_hash("UnknownEvent", { foo: "bar" })
      expect(event).to be_nil
    end

    it "filters out extra payload keys" do
      payload = {
        example_id:       "abc123",
        description:      "test",
        full_description: "full test",
        location:         "spec/test.rb:1",
        time:             time,
        extra_field:      "should be ignored"
      }

      event = described_class.from_hash("ExampleStarted", payload)

      expect(event).to be_a(RSpec::Agents::Events::ExampleStarted)
      expect(event.to_h).not_to have_key(:extra_field)
    end
  end

  describe RSpec::Agents::Events::SimulationStarted do
    it "creates an event with all required fields" do
      event = described_class.new(
        example_id: "abc123",
        goal:       "Book a venue for 50 people",
        max_turns:  15,
        time:       time
      )

      expect(event.example_id).to eq("abc123")
      expect(event.goal).to eq("Book a venue for 50 people")
      expect(event.max_turns).to eq(15)
      expect(event.time).to eq(time)
    end
  end

  describe RSpec::Agents::Events::SimulationEnded do
    it "creates an event with all required fields" do
      event = described_class.new(
        example_id:         "abc123",
        turn_count:         5,
        termination_reason: :stop_condition,
        time:               time
      )

      expect(event.example_id).to eq("abc123")
      expect(event.turn_count).to eq(5)
      expect(event.termination_reason).to eq(:stop_condition)
      expect(event.time).to eq(time)
    end

    it "supports different termination reasons" do
      max_turns_event = described_class.new(
        example_id:         "abc123",
        turn_count:         15,
        termination_reason: :max_turns,
        time:               time
      )

      expect(max_turns_event.termination_reason).to eq(:max_turns)
    end
  end

  describe RSpec::Agents::Events::EvaluationRecorded do
    it "creates an event with all required fields for soft evaluation" do
      event = described_class.new(
        example_id:      "abc123",
        turn_number:     1,
        mode:            :soft,
        type:            :quality,
        description:     "satisfy(friendly)",
        passed:          true,
        failure_message: nil,
        metadata:        { criteria: ["friendly"] },
        time:            time
      )

      expect(event.example_id).to eq("abc123")
      expect(event.turn_number).to eq(1)
      expect(event.mode).to eq(:soft)
      expect(event.type).to eq(:quality)
      expect(event.description).to eq("satisfy(friendly)")
      expect(event.passed).to be true
      expect(event.failure_message).to be_nil
      expect(event.metadata).to eq({ criteria: ["friendly"] })
      expect(event.time).to eq(time)
    end

    it "creates an event with all required fields for hard expectation" do
      event = described_class.new(
        example_id:      "abc123",
        turn_number:     2,
        mode:            :hard,
        type:            :tool_call,
        description:     "call_tool(:search)",
        passed:          false,
        failure_message: "Expected call to :search but no tool calls were made",
        metadata:        { tool_name: "search" },
        time:            time
      )

      expect(event.mode).to eq(:hard)
      expect(event.type).to eq(:tool_call)
      expect(event.passed).to be false
      expect(event.failure_message).to eq("Expected call to :search but no tool calls were made")
    end
  end

  describe "EVENT_TYPES" do
    it "includes all defined event classes" do
      expected_types = %w[
        SuiteStarted SuiteStopped SuiteSummary
        GroupStarted GroupFinished
        ExampleStarted ExamplePassed ExampleFailed ExamplePending
        SimulationStarted SimulationEnded
        UserMessage AgentResponse TopicChanged
        ToolCallCompleted
        EvaluationRecorded
      ]

      expect(described_class::EVENT_TYPES.keys).to match_array(expected_types)
    end
  end
end
