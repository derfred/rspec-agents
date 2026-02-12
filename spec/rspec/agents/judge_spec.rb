require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::Judge do
  let(:mock_llm) { RSpec::Agents::Llm::Mock.new }
  let(:criteria) do
    {
      friendly:      RSpec::Agents::DSL::CriterionDefinition.new(:friendly, description: "The agent should be friendly"),
      helpful:       RSpec::Agents::DSL::CriterionDefinition.new(:helpful, description: "The agent should be helpful"),
      code_based:    RSpec::Agents::DSL::CriterionDefinition.new(:code_based) do
        match { |conversation| conversation.has_tool_call?(:search) }
      end,
      message_based: RSpec::Agents::DSL::CriterionDefinition.new(:message_based) do
        match_messages { |messages| messages.any? { |m| m[:content]&.include?("hello") } }
      end
    }
  end

  subject(:judge) { described_class.new(llm: mock_llm, criteria: criteria) }

  def build_turn(user_message:, agent_text:, tool_calls: [])
    response = RSpec::Agents::AgentResponse.new(text: agent_text, tool_calls: tool_calls)
    RSpec::Agents::Turn.new(user_message, response)
  end

  def build_conversation(messages: [], tool_calls: [])
    conversation = RSpec::Agents::Conversation.new
    messages.each { |m| conversation.add_user_message(m) }
    conversation
  end

  describe "#initialize" do
    it "stores llm and criteria" do
      expect(judge.llm).to eq(mock_llm)
      expect(judge.criteria).to eq(criteria)
    end

    it "defaults criteria to empty hash" do
      judge = described_class.new(llm: mock_llm)
      expect(judge.criteria).to eq({})
    end
  end

  describe "#classify_topic" do
    let(:turn) { build_turn(user_message: "Find venues", agent_text: "I found some venues for you") }
    let(:conversation) { build_conversation }

    let(:topic_greeting) do
      RSpec::Agents::Topic.new(:greeting) { characteristic "Initial contact phase" }
    end
    let(:topic_gathering) do
      RSpec::Agents::Topic.new(:gathering) { characteristic "Collecting requirements" }
    end
    let(:topic_presenting) do
      RSpec::Agents::Topic.new(:presenting) { characteristic "Showing results" }
    end

    it "returns single topic immediately when only one possible" do
      result = judge.classify_topic(turn, conversation, [topic_greeting])
      expect(result).to eq(:greeting)
    end

    it "does not call LLM when only one topic possible" do
      judge.classify_topic(turn, conversation, [topic_greeting])
      expect(mock_llm.calls).to be_empty
    end

    it "uses LLM classification when multiple topics possible" do
      mock_llm.queue_topic_classification(:presenting)

      result = judge.classify_topic(turn, conversation, [topic_gathering, topic_presenting])
      expect(result).to eq(:presenting)
    end

    it "calls LLM with topic classification prompt" do
      mock_llm.queue_topic_classification(:gathering)

      judge.classify_topic(turn, conversation, [topic_gathering, topic_presenting])

      expect(mock_llm.calls).not_to be_empty
      expect(mock_llm.last_prompt).to include("classify")
    end

    it "handles LLM returning invalid topic by falling back to first" do
      # Mock returns topic not in the valid list
      mock_llm.set_default_response(/topic/, '{"topic": "invalid_topic"}')

      result = judge.classify_topic(turn, conversation, [topic_gathering, topic_presenting])
      expect(result).to eq(:gathering)
    end
  end

  describe "#evaluate_criterion" do
    let(:turn) { build_turn(user_message: "Hello", agent_text: "Hi there! How can I help?") }
    let(:conversation) do
      conv = build_conversation
      conv.add_user_message("Hello")
      response = RSpec::Agents::AgentResponse.new(text: "Hi there! How can I help?")
      conv.add_agent_response(response)
      conv
    end

    context "with named criterion" do
      it "returns failure for unknown criterion" do
        result = judge.evaluate_criterion(:unknown, [turn], conversation)

        expect(result[:satisfied]).to be false
        expect(result[:reasoning]).to include("Unknown criterion")
      end

      it "uses LLM evaluation for semantic criteria" do
        mock_llm.set_evaluation(:friendly, true, "Agent was very welcoming")

        result = judge.evaluate_criterion(:friendly, [turn], conversation)

        expect(result[:satisfied]).to be true
        expect(result[:reasoning]).to include("welcoming")
      end

      it "calls LLM with criterion in prompt" do
        mock_llm.set_evaluation(:friendly, true)

        judge.evaluate_criterion(:friendly, [turn], conversation)

        expect(mock_llm.last_prompt).to include("friendly")
      end

      it "handles LLM returning unsatisfied" do
        mock_llm.set_evaluation(:helpful, false, "Agent did not provide actionable help")

        result = judge.evaluate_criterion(:helpful, [turn], conversation)

        expect(result[:satisfied]).to be false
        expect(result[:reasoning]).to include("actionable")
      end
    end

    context "with code-based criterion using match block" do
      it "uses match block instead of LLM" do
        conv_with_tool = RSpec::Agents::Conversation.new
        conv_with_tool.add_user_message("Search for venues")
        response = RSpec::Agents::AgentResponse.new(
          text:       "Searching...",
          tool_calls: [RSpec::Agents::ToolCall.new(name: :search, arguments: {})]
        )
        conv_with_tool.add_agent_response(response)

        result = judge.evaluate_criterion(:code_based, [turn], conv_with_tool)

        expect(result[:satisfied]).to be true
        expect(result[:reasoning]).to include("Code-based criterion passed")
        expect(mock_llm.calls).to be_empty
      end

      it "returns failure when match block returns false" do
        # Conversation without the expected tool call
        empty_conv = RSpec::Agents::Conversation.new

        result = judge.evaluate_criterion(:code_based, [turn], empty_conv)

        expect(result[:satisfied]).to be false
        expect(result[:reasoning]).to include("Code-based criterion failed")
      end
    end

    context "with code-based criterion using match_messages block" do
      it "evaluates using match_messages block" do
        conv = RSpec::Agents::Conversation.new
        conv.add_user_message("hello there")

        result = judge.evaluate_criterion(:message_based, [turn], conv)

        expect(result[:satisfied]).to be true
        expect(mock_llm.calls).to be_empty
      end

      it "fails when match_messages returns false" do
        conv = RSpec::Agents::Conversation.new
        conv.add_user_message("goodbye")

        result = judge.evaluate_criterion(:message_based, [turn], conv)

        expect(result[:satisfied]).to be false
      end
    end

    context "with string criterion name" do
      it "resolves string to symbol" do
        mock_llm.set_evaluation(:friendly, true, "Agent was friendly")

        result = judge.evaluate_criterion("friendly", [turn], conversation)

        expect(result[:satisfied]).to be true
      end
    end
  end

  describe "#evaluate_grounding" do
    let(:tool_call) do
      RSpec::Agents::ToolCall.new(
        name:      :search_venues,
        arguments: { location: "Stuttgart" },
        result:    { venues: [{ name: "Blue Room", price: 500 }] }
      )
    end

    let(:turn) do
      build_turn(
        user_message: "Find venues",
        agent_text:   "I found the Blue Room for 500 EUR",
        tool_calls:   [tool_call]
      )
    end

    it "evaluates grounding via LLM" do
      result = judge.evaluate_grounding([:venues, :pricing], [turn])

      expect(result).to have_key(:grounded)
      expect(mock_llm.calls).not_to be_empty
    end

    it "filters tool calls by from_tools when specified" do
      other_tool = RSpec::Agents::ToolCall.new(name: :other_tool, arguments: {})
      turn_with_multiple = build_turn(
        user_message: "Find venues",
        agent_text:   "Found venues",
        tool_calls:   [tool_call, other_tool]
      )

      judge.evaluate_grounding([:venues], [turn_with_multiple], from_tools: [:search_venues])

      prompt = mock_llm.last_prompt
      expect(prompt).to include("search_venues")
    end

    it "combines multiple agent texts for evaluation" do
      turn1 = build_turn(user_message: "Q1", agent_text: "Response 1", tool_calls: [tool_call])
      turn2 = build_turn(user_message: "Q2", agent_text: "Response 2")

      judge.evaluate_grounding([:venues], [turn1, turn2])

      prompt = mock_llm.last_prompt
      expect(prompt).to include("Response 1")
      expect(prompt).to include("Response 2")
    end

    it "handles turns without agent responses" do
      empty_turn = RSpec::Agents::Turn.new("Question", nil)

      result = judge.evaluate_grounding([:venues], [empty_turn])

      expect(result).to have_key(:grounded)
    end
  end

  describe "#evaluate_forbidden_claims" do
    let(:turn) do
      build_turn(
        user_message: "What's available?",
        agent_text:   "The Blue Room is available on Monday"
      )
    end

    it "detects forbidden claims via LLM" do
      mock_llm.set_default_response(/forbid|claim/, '{"violated": true, "claims_found": [{"type": "availability", "claim": "available on Monday"}]}')

      result = judge.evaluate_forbidden_claims([:availability], [turn])

      expect(result).to have_key(:violated)
      expect(mock_llm.calls).not_to be_empty
    end

    it "includes claim types in prompt" do
      judge.evaluate_forbidden_claims([:availability, :pricing], [turn])

      prompt = mock_llm.last_prompt
      expect(prompt).to include("availability")
      expect(prompt).to include("pricing")
    end

    it "combines multiple turns for evaluation" do
      turn2 = build_turn(user_message: "Q2", agent_text: "More info here")

      judge.evaluate_forbidden_claims([:availability], [turn, turn2])

      prompt = mock_llm.last_prompt
      expect(prompt).to include("The Blue Room")
      expect(prompt).to include("More info here")
    end
  end

  describe "#evaluate_intent" do
    let(:turn) do
      build_turn(
        user_message: "I need help",
        agent_text:   "Sure! What dates work for you? How many people will attend?"
      )
    end

    it "evaluates intent via LLM" do
      result = judge.evaluate_intent("Gather requirements about dates and capacity", turn)

      expect(result).to have_key(:matches)
      expect(mock_llm.calls).not_to be_empty
    end

    it "includes intent description in prompt" do
      judge.evaluate_intent("Ask clarifying questions", turn)

      prompt = mock_llm.last_prompt
      expect(prompt).to include("Ask clarifying questions")
    end

    it "accepts context parameter" do
      judge.evaluate_intent("Gather requirements", turn, { topic: :gathering })

      # Should not raise
      expect(mock_llm.calls).not_to be_empty
    end
  end

  describe "#resolve_pending_invariants" do
    let(:turn) { build_turn(user_message: "Hello", agent_text: "Hi there!") }
    let(:conversation) { build_conversation }

    describe "quality type invariants" do
      it "resolves quality evaluations" do
        mock_llm.set_evaluation(:friendly, true, "Agent was friendly")

        pending = [{ type: :quality, data: [:friendly] }]
        results = judge.resolve_pending_invariants(pending, [turn], conversation)

        expect(results.length).to eq(1)
        expect(results.first[:type]).to eq(:quality)
        expect(results.first[:passed]).to be true
      end

      it "fails when any criterion unsatisfied" do
        mock_llm.set_evaluation(:friendly, true)
        mock_llm.set_evaluation(:helpful, false, "Not helpful")

        pending = [{ type: :quality, data: [:friendly, :helpful] }]
        results = judge.resolve_pending_invariants(pending, [turn], conversation)

        expect(results.first[:passed]).to be false
        expect(results.first[:failure_message]).to include("not satisfied")
      end
    end

    describe "grounding type invariants" do
      it "resolves grounding evaluations" do
        pending = [{
          type: :grounding,
          data: { claim_types: [:venues], from_tools: [:search] }
        }]

        results = judge.resolve_pending_invariants(pending, [turn], conversation)

        expect(results.first[:type]).to eq(:grounding)
        expect(results.first[:description]).to include("venues")
      end

      it "includes failure message when not grounded" do
        # Use a custom LLM that returns failed grounding
        failing_llm = instance_double(RSpec::Agents::Llm::Base)
        allow(failing_llm).to receive(:complete) do |prompt, **_opts|
          RSpec::Agents::Llm::Response.new(
            text:     '{"grounded": false, "violations": ["Price not grounded"]}',
            parsed:   { "grounded" => false, "violations" => ["Price not grounded"] },
            metadata: {}
          )
        end

        failing_judge = RSpec::Agents::Judge.new(llm: failing_llm, criteria: criteria)

        pending = [{
          type: :grounding,
          data: { claim_types: [:pricing], from_tools: [] }
        }]

        results = failing_judge.resolve_pending_invariants(pending, [turn], conversation)

        expect(results.first[:passed]).to be false
        expect(results.first[:failure_message]).to include("Ungrounded")
      end
    end

    describe "forbidden_claims type invariants" do
      it "resolves forbidden claims evaluations" do
        pending = [{ type: :forbidden_claims, data: [:availability] }]

        results = judge.resolve_pending_invariants(pending, [turn], conversation)

        expect(results.first[:type]).to eq(:forbidden_claims)
        expect(results.first[:description]).to include("availability")
      end

      it "fails when forbidden claims found" do
        # Use a custom LLM that returns violated
        failing_llm = instance_double(RSpec::Agents::Llm::Base)
        allow(failing_llm).to receive(:complete) do |prompt, **_opts|
          RSpec::Agents::Llm::Response.new(
            text:     '{"violated": true, "claims_found": [{"claim": "available Monday"}]}',
            parsed:   { "violated" => true, "claims_found" => [{ "claim" => "available Monday" }] },
            metadata: {}
          )
        end

        failing_judge = RSpec::Agents::Judge.new(llm: failing_llm, criteria: criteria)

        pending = [{ type: :forbidden_claims, data: [:availability] }]

        results = failing_judge.resolve_pending_invariants(pending, [turn], conversation)

        expect(results.first[:passed]).to be false
        expect(results.first[:failure_message]).to include("Forbidden claims found")
      end
    end

    describe "unknown type invariants" do
      it "handles unknown evaluation types gracefully" do
        pending = [{ type: :unknown_type, data: {} }]

        results = judge.resolve_pending_invariants(pending, [turn], conversation)

        expect(results.first[:type]).to eq(:unknown_type)
        expect(results.first[:passed]).to be true
        expect(results.first[:failure_message]).to be_nil
      end
    end

    it "processes multiple pending invariants" do
      mock_llm.set_evaluation(:friendly, true)

      pending = [
        { type: :quality, data: [:friendly] },
        { type: :grounding, data: { claim_types: [:venues], from_tools: [] } },
        { type: :forbidden_claims, data: [:availability] }
      ]

      results = judge.resolve_pending_invariants(pending, [turn], conversation)

      expect(results.length).to eq(3)
      expect(results.map { |r| r[:type] }).to contain_exactly(:quality, :grounding, :forbidden_claims)
    end
  end

  describe "private methods" do
    describe "#build_evaluation_context" do
      it "includes tool call summary when tools were called" do
        conversation = RSpec::Agents::Conversation.new
        conversation.add_user_message("Search for venues")
        response = RSpec::Agents::AgentResponse.new(
          text:       "Found venues",
          tool_calls: [
            RSpec::Agents::ToolCall.new(name: :search_venues, arguments: {}),
            RSpec::Agents::ToolCall.new(name: :get_details, arguments: {})
          ]
        )
        conversation.add_agent_response(response)

        # Access private method for testing
        context = judge.send(:build_evaluation_context, conversation)

        expect(context["Tools called"]).to include("search_venues")
        expect(context["Tools called"]).to include("get_details")
      end

      it "returns empty context when no tools called" do
        conversation = RSpec::Agents::Conversation.new
        context = judge.send(:build_evaluation_context, conversation)

        expect(context).to eq({})
      end
    end
  end
end
