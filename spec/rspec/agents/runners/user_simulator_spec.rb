require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::Runners::UserSimulator do
  # Mock agent that returns configurable responses
  let(:mock_agent) do
    agent = instance_double(RSpec::Agents::Agents::Base)
    allow(agent).to receive(:chat) do |messages|
      response_text = @agent_responses.shift || "Default agent response"
      tool_calls = @agent_tool_calls.shift || []
      RSpec::Agents::AgentResponse.new(text: response_text, tool_calls: tool_calls)
    end
    agent
  end

  let(:mock_llm) { RSpec::Agents::Llm::Mock.new }

  let(:criteria) do
    {
      friendly: RSpec::Agents::DSL::CriterionDefinition.new(:friendly, description: "Agent should be friendly")
    }
  end

  let(:judge) { RSpec::Agents::Judge.new(llm: mock_llm, criteria: criteria) }

  let(:simulator_config) do
    config = RSpec::Agents::SimulatorConfig.new
    config.goal "Find a venue for 50 attendees"
    config.max_turns 5
    config
  end

  def build_topic(name, next_topics: [], &block)
    RSpec::Agents::Topic.new(name, &block)
  end

  def build_graph(topics_with_edges)
    graph = RSpec::Agents::TopicGraph.new
    topics_with_edges.each do |topic, next_topics|
      graph.add_topic(topic, next_topics: next_topics)
    end
    graph.validate!
    graph
  end

  # Build a TurnExecutor wrapping the given agent with a fresh conversation
  def build_turn_executor(agent)
    conversation = RSpec::Agents::Conversation.new
    RSpec::Agents::TurnExecutor.new(
      agent:        agent,
      conversation: conversation,
      graph:        nil,
      judge:        nil,
      event_bus:    nil
    )
  end

  before do
    @agent_responses = []
    @agent_tool_calls = []
  end

  describe "#initialize" do
    let(:graph) do
      build_graph({
        build_topic(:greeting) { characteristic "Initial contact" }  => :gathering,
        build_topic(:gathering) { characteristic "Collecting info" } => []
      })
    end

    it "stores all dependencies" do
      runner = described_class.new(
        turn_executor:    build_turn_executor(mock_agent),
        llm:              mock_llm,
        judge:            judge,
        graph:            graph,
        simulator_config: simulator_config
      )

      expect(runner.conversation).to be_a(RSpec::Agents::Conversation)
      expect(runner.results).to be_a(RSpec::Agents::Runners::SimulationResults)
    end
  end

  describe "#run" do
    let(:topic_greeting) do
      build_topic(:greeting) do
        characteristic "Initial contact phase"
        agent_intent "Welcome the user"
      end
    end

    let(:topic_gathering) do
      build_topic(:gathering) do
        characteristic "Collecting event requirements"
        triggers { on_tool_call :search_venues }
      end
    end

    let(:topic_presenting) do
      build_topic(:presenting) do
        characteristic "Showing search results"
      end
    end

    let(:graph) do
      build_graph({
        topic_greeting   => :gathering,
        topic_gathering  => :presenting,
        topic_presenting => []
      })
    end

    subject(:runner) do
      described_class.new(
        turn_executor:    build_turn_executor(mock_agent),
        llm:              mock_llm,
        judge:            judge,
        graph:            graph,
        simulator_config: simulator_config
      )
    end

    it "generates user messages via LLM" do
      mock_llm.queue_user_response("Hello, I need help finding a venue")
      mock_llm.queue_user_response("For 50 people in Stuttgart")
      @agent_responses = ["Welcome! How can I help?", "Let me search for you"]

      runner.run

      expect(runner.conversation.turns.length).to be >= 1
      expect(runner.conversation.messages.any?(&:user?)).to be true
    end

    it "gets agent responses and records turns" do
      mock_llm.queue_user_response("Hello")
      @agent_responses = ["Welcome! How can I help you today?"]
      simulator_config.max_turns 1

      runner.run

      expect(runner.conversation.turns.length).to eq(1)
      turn = runner.conversation.turns.first
      expect(turn.user_message).to eq("Hello")
      expect(turn.agent_response.text).to include("Welcome")
    end

    it "respects max_turns limit" do
      5.times { mock_llm.queue_user_response("User message") }
      @agent_responses = ["Response"] * 5
      simulator_config.max_turns 3

      runner.run

      expect(runner.conversation.turns.length).to eq(3)
    end

    it "respects stop_when condition" do
      mock_llm.queue_user_response("Start")
      mock_llm.queue_user_response("Book it")
      @agent_responses = [
        "Welcome!",
        "Booking now..."
      ]
      @agent_tool_calls = [
        [],
        [RSpec::Agents::ToolCall.new(name: :book_venue, arguments: {})]
      ]

      simulator_config.stop_when do |turn, conversation|
        conversation.has_tool_call?(:book_venue)
      end

      runner.run

      expect(runner.conversation.has_tool_call?(:book_venue)).to be true
      # Should stop after the book_venue call
      expect(runner.conversation.turns.length).to eq(2)
    end

    it "starts in the initial topic" do
      mock_llm.queue_user_response("Hello")
      @agent_responses = ["Welcome!"]
      simulator_config.max_turns 1

      runner.run

      expect(runner.conversation.current_topic).not_to be_nil
    end

    describe "topic classification" do
      it "classifies topics using triggers first" do
        # Create a topic graph where the successor topic has a trigger
        topic_start = build_topic(:start) { characteristic "Starting point" }
        topic_with_trigger = build_topic(:triggered) do
          characteristic "Topic activated by tool call"
          triggers { on_tool_call :search_venues }
        end

        trigger_graph = build_graph({
          topic_start        => :triggered,
          topic_with_trigger => []
        })

        # Create a dedicated mock agent for this test with its own response queue
        local_responses = ["Searching..."]
        local_tool_calls = [[RSpec::Agents::ToolCall.new(name: :search_venues, arguments: {})]]
        local_agent = instance_double(RSpec::Agents::Agents::Base)
        allow(local_agent).to receive(:chat) do |_messages|
          text = local_responses.shift || "Default"
          tools = local_tool_calls.shift || []
          RSpec::Agents::AgentResponse.new(text: text, tool_calls: tools)
        end

        local_config = RSpec::Agents::SimulatorConfig.new
        local_config.goal "Test trigger classification"
        local_config.max_turns 1

        local_llm = RSpec::Agents::Llm::Mock.new
        local_llm.queue_user_response("Find venues")

        local_runner = described_class.new(
          turn_executor:    build_turn_executor(local_agent),
          llm:              local_llm,
          judge:            RSpec::Agents::Judge.new(llm: local_llm, criteria: criteria),
          graph:            trigger_graph,
          simulator_config: local_config
        )

        local_runner.run

        # The conversation should have transitioned to :triggered based on the trigger
        # Note: Turn's topic records where it was WHEN recorded, not where it transitioned TO
        # The current_topic reflects the final state after classification
        expect(local_runner.conversation.current_topic).to eq(:triggered)

        # LLM should NOT have been called for classification since trigger matched
        classification_calls = local_llm.calls.select { |c| c[:prompt].include?("classify") }
        expect(classification_calls).to be_empty
      end

      it "falls back to LLM classification when no triggers match" do
        mock_llm.queue_user_response("Hello there")
        mock_llm.queue_topic_classification(:gathering)
        @agent_responses = ["Hi! What kind of event are you planning?"]
        simulator_config.max_turns 1

        runner.run

        # LLM should have been called for classification
        expect(mock_llm.calls.any? { |c| c[:prompt].include?("classify") }).to be true
      end

      it "stays in current topic when current topic triggers match (conservative)" do
        # Create topics where greeting has its own trigger
        topic_greeting_with_trigger = build_topic(:greeting) do
          characteristic "Initial contact"
          triggers { on_response_match /welcome|hello/i }
        end
        topic_gathering = build_topic(:gathering) { characteristic "Collecting info" }

        graph = build_graph({
          topic_greeting_with_trigger => :gathering,
          topic_gathering             => []
        })

        runner = described_class.new(
          turn_executor:    build_turn_executor(mock_agent),
          llm:              mock_llm,
          judge:            judge,
          graph:            graph,
          simulator_config: simulator_config
        )

        mock_llm.queue_user_response("Hi")
        @agent_responses = ["Welcome! How can I help?"]
        simulator_config.max_turns 1

        runner.run

        # Should stay in greeting because the greeting trigger matched
        last_turn = runner.conversation.turns.last
        expect(last_turn.topic).to eq(:greeting)
      end
    end

    describe "invariant evaluation" do
      it "evaluates invariants on topic exit" do
        topic_with_invariants = build_topic(:greeting) do
          characteristic "Initial contact"
          expect_agent to_satisfy: [:friendly]
        end
        topic_next = build_topic(:next_topic) do
          characteristic "Next phase"
          triggers { on_response_match /next phase/i }
        end

        graph = build_graph({
          topic_with_invariants => :next_topic,
          topic_next            => []
        })

        runner = described_class.new(
          turn_executor:    build_turn_executor(mock_agent),
          llm:              mock_llm,
          judge:            judge,
          graph:            graph,
          simulator_config: simulator_config
        )

        mock_llm.queue_user_response("Hello")
        mock_llm.queue_user_response("Continue")
        mock_llm.set_evaluation(:friendly, true, "Agent was friendly")
        @agent_responses = ["Welcome!", "Moving to next phase now"]
        simulator_config.max_turns 2

        runner.run
        results = runner.simulation_results

        # Should have evaluated the greeting topic
        expect(results.evaluations.map { |e| e[:topic] }).to include(:greeting)
      end

      it "evaluates invariants for final topic" do
        mock_llm.queue_user_response("Hello")
        @agent_responses = ["Welcome!"]
        simulator_config.max_turns 1

        runner.run
        results = runner.simulation_results

        # Final topic should also be evaluated
        expect(results.evaluations).not_to be_empty
      end
    end
  end

  describe "#simulation_results" do
    let(:graph) do
      build_graph({
        build_topic(:greeting) { characteristic "Initial contact" } => []
      })
    end

    subject(:runner) do
      described_class.new(
        turn_executor:    build_turn_executor(mock_agent),
        llm:              mock_llm,
        judge:            judge,
        graph:            graph,
        simulator_config: simulator_config
      )
    end

    it "returns SimulationResults object" do
      expect(runner.simulation_results).to be_a(RSpec::Agents::Runners::SimulationResults)
    end
  end

  describe RSpec::Agents::Runners::SimulationResults do
    subject(:results) { described_class.new }

    describe "#initialize" do
      it "starts with empty state" do
        expect(results.evaluations).to eq([])
      end
    end

    describe "#add_topic_evaluation" do
      let(:invariant_results) do
        ir = RSpec::Agents::InvariantResults.new(:greeting)
        ir.add(:pattern, "to_match /hello/", true, nil)
        ir
      end

      let(:failed_invariant_results) do
        ir = RSpec::Agents::InvariantResults.new(:greeting)
        ir.add(:pattern, "to_match /goodbye/", false, "Pattern not found")
        ir
      end

      it "tracks topic evaluations" do
        results.add_topic_evaluation(:greeting, invariant_results)

        expect(results.evaluations.first[:topic]).to eq(:greeting)
        expect(results.evaluations.first[:results]).to eq(invariant_results)
      end

      it "reports failures from failed invariants" do
        results.add_topic_evaluation(:greeting, failed_invariant_results)

        expect(results.passed?).to be false
        expect(results.failure_messages).to include("Pattern not found")
      end

      it "passes when invariants pass" do
        results.add_topic_evaluation(:greeting, invariant_results)

        expect(results.passed?).to be true
      end
    end

    describe "#passed?" do
      let(:passing_results) do
        ir = RSpec::Agents::InvariantResults.new(:topic)
        ir.add(:test, "test", true, nil)
        ir
      end

      let(:failing_results) do
        ir = RSpec::Agents::InvariantResults.new(:topic)
        ir.add(:test, "test", false, "Failed")
        ir
      end

      it "returns true when no failures" do
        results.add_topic_evaluation(:greeting, passing_results)

        expect(results.passed?).to be true
      end

      it "returns false when there are failures" do
        results.add_topic_evaluation(:greeting, failing_results)

        expect(results.passed?).to be false
      end
    end

    describe "#failure_messages" do
      it "returns list of failure messages" do
        ir = RSpec::Agents::InvariantResults.new(:topic)
        ir.add(:test1, "test1", false, "First failure")
        ir.add(:test2, "test2", false, "Second failure")
        results.add_topic_evaluation(:topic, ir)

        messages = results.failure_messages

        expect(messages).to include("First failure")
        expect(messages).to include("Second failure")
      end

      it "filters nil messages" do
        ir = RSpec::Agents::InvariantResults.new(:topic)
        ir.add(:test, "test", true, nil)
        results.add_topic_evaluation(:topic, ir)

        expect(results.failure_messages).to eq([])
      end
    end

    describe "#to_h" do
      it "returns hash representation" do
        ir = RSpec::Agents::InvariantResults.new(:greeting)
        ir.add(:test, "test", true, nil)
        results.add_topic_evaluation(:greeting, ir)

        hash = results.to_h

        expect(hash).to have_key(:evaluations)
        expect(hash).to have_key(:passed)
        expect(hash[:passed]).to be true
      end
    end
  end

  describe "edge cases" do
    let(:graph) do
      build_graph({
        build_topic(:only) { characteristic "Only topic" } => []
      })
    end

    subject(:runner) do
      described_class.new(
        turn_executor:    build_turn_executor(mock_agent),
        llm:              mock_llm,
        judge:            judge,
        graph:            graph,
        simulator_config: simulator_config
      )
    end

    it "raises error for empty topic graph" do
      # Empty topic graphs are invalid for simulation - need at least one topic
      empty_graph = RSpec::Agents::TopicGraph.new

      local_config = RSpec::Agents::SimulatorConfig.new
      local_config.goal "Test goal"
      local_config.max_turns 1

      runner = described_class.new(
        turn_executor:    build_turn_executor(mock_agent),
        llm:              mock_llm,
        judge:            judge,
        graph:            empty_graph,
        simulator_config: local_config
      )

      mock_llm.queue_user_response("Hello")
      @agent_responses = ["Hi"]

      # Empty graph results in nil initial_topic which causes an error
      # This is expected - simulations require at least one topic
      expect { runner.run }.to raise_error(NoMethodError)
    end

    it "handles terminal topic with no successors" do
      terminal_topic = build_topic(:terminal) { characteristic "End state" }
      graph = build_graph({ terminal_topic => [] })

      runner = described_class.new(
        turn_executor:    build_turn_executor(mock_agent),
        llm:              mock_llm,
        judge:            judge,
        graph:            graph,
        simulator_config: simulator_config
      )

      mock_llm.queue_user_response("Done")
      @agent_responses = ["Goodbye!"]
      simulator_config.max_turns 1

      runner.run

      # Should stay in terminal topic
      expect(runner.conversation.current_topic).to eq(:terminal)
    end

    it "handles max_turns of 0" do
      simulator_config.max_turns 0

      runner.run

      expect(runner.conversation.turns).to be_empty
    end
  end
end
