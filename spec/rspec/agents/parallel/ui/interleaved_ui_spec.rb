require "spec_helper"
require "rspec/agents"
require "stringio"

RSpec.describe RSpec::Agents::Parallel::UI::InterleavedUI do
  let(:output) { StringIO.new }
  let(:ui) { described_class.new(output: output, color: false) }
  let(:time) { Time.now }

  def output_lines
    output.string.lines.map(&:chomp)
  end

  describe "#on_run_started" do
    it "prints the header with worker count" do
      ui.on_run_started(worker_count: 4, example_count: 10)

      expect(output.string).to include("Parallel spec runner")
      expect(output.string).to include("4 workers")
    end
  end

  describe "#on_example_started" do
    before { ui.on_run_started(worker_count: 4, example_count: 10) }

    it "prints example start with worker prefix" do
      event = RSpec::Agents::Events::ExampleStarted.new(
        example_id:       "test1",
        stable_id:        nil,
        canonical_path:   nil,
        description:      "creates user account",
        full_description: "creates user account",
        location:         "spec/test_spec.rb:1",
        scenario:         nil,
        time:             time
      )

      ui.on_example_started(worker: 0, event: event)

      expect(output.string).to include("[1]")
      expect(output.string).to include("creates user account")
    end

    it "uses different prefixes for different workers" do
      event1 = RSpec::Agents::Events::ExampleStarted.new(
        example_id: "test1", stable_id: nil, canonical_path: nil,
        description: "test one", full_description: "test one",
        location: "spec/a_spec.rb:1", scenario: nil, time: time
      )
      event2 = RSpec::Agents::Events::ExampleStarted.new(
        example_id: "test2", stable_id: nil, canonical_path: nil,
        description: "test two", full_description: "test two",
        location: "spec/b_spec.rb:1", scenario: nil, time: time
      )

      ui.on_example_started(worker: 0, event: event1)
      ui.on_example_started(worker: 1, event: event2)

      lines = output_lines
      expect(lines.any? { |l| l.include?("[1]") && l.include?("test one") }).to be true
      expect(lines.any? { |l| l.include?("[2]") && l.include?("test two") }).to be true
    end
  end

  describe "#on_example_finished" do
    before { ui.on_run_started(worker_count: 2, example_count: 5) }

    it "prints pass status with duration" do
      event = RSpec::Agents::Events::ExamplePassed.new(
        example_id:       "test1",
        stable_id:        nil,
        description:      "passing test",
        full_description: "passing test",
        duration:         1.5,
        time:             time
      )

      ui.on_example_finished(worker: 0, event: event)

      expect(output.string).to include("[1]")
      expect(output.string).to include("1.5s")
    end

    it "prints failure status and collects failure" do
      event = RSpec::Agents::Events::ExampleFailed.new(
        example_id:       "test1",
        stable_id:        nil,
        description:      "failing test",
        full_description: "failing test",
        location:         "spec/test_spec.rb:5",
        duration:         0.5,
        message:          "Expected true but got false",
        backtrace:        ["spec/test_spec.rb:5"],
        time:             time
      )

      ui.on_example_finished(worker: 1, event: event)

      expect(output.string).to include("[2]")
      expect(output.string).to include("FAILED")
      expect(output.string).to include("Expected true but got false")
      expect(ui.failures).to include(event)
    end

    it "prints pending status" do
      event = RSpec::Agents::Events::ExamplePending.new(
        example_id:       "test1",
        stable_id:        nil,
        description:      "pending test",
        full_description: "pending test",
        message:          "Not implemented yet",
        time:             time
      )

      ui.on_example_finished(worker: 0, event: event)

      expect(output.string).to include("pending")
      expect(output.string).to include("Not implemented yet")
    end
  end

  describe "#on_conversation_event" do
    before { ui.on_run_started(worker_count: 2, example_count: 2) }

    it "prints user messages with prefix" do
      event = RSpec::Agents::Events::UserMessage.new(
        example_id:  "test1",
        turn_number: 1,
        text:        "Hello, I need help",
        source:      :script,
        time:        time
      )

      ui.on_conversation_event(worker: 0, event: event)

      expect(output.string).to include("[1]")
      expect(output.string).to include("User:")
      expect(output.string).to include("Hello, I need help")
    end

    it "prints agent responses with prefix" do
      event = RSpec::Agents::Events::AgentResponse.new(
        example_id:  "test1",
        turn_number: 1,
        text:        "I can help you with that",
        tool_calls:  [],
        metadata:    nil,
        time:        time
      )

      ui.on_conversation_event(worker: 1, event: event)

      expect(output.string).to include("[2]")
      expect(output.string).to include("Agent:")
      expect(output.string).to include("I can help you")
    end

    it "prints tool calls with prefix" do
      event = RSpec::Agents::Events::ToolCallCompleted.new(
        example_id:  "test1",
        turn_number: 1,
        tool_name:   :search_venues,
        arguments:   { location: "Berlin" },
        result:      nil,
        time:        time
      )

      ui.on_conversation_event(worker: 0, event: event)

      expect(output.string).to include("[1]")
      expect(output.string).to include("search_venues")
      expect(output.string).to include("location")
    end
  end

  describe "color support" do
    it "applies colors when enabled" do
      colored_ui = described_class.new(output: output, color: true)
      colored_ui.on_run_started(worker_count: 2, example_count: 2)

      expect(output.string).to include("\e[")
    end

    it "does not apply colors when disabled" do
      ui.on_run_started(worker_count: 2, example_count: 2)

      expect(output.string).not_to include("\e[")
    end
  end
end
