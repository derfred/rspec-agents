require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::Matchers do
  # Include the matchers module for testing
  include described_class

  # Mock runner that provides the interface expected by matchers
  class MockRunner
    attr_accessor :current_turn, :current_topic

    def initialize
      @current_turn = nil
      @current_topic = nil
      @criterion_results = {}
      @grounding_result = { grounded: true, violations: [] }
      @forbidden_claims_result = { violated: false, claims_found: [] }
      @intent_result = { matches: true, observed_intent: "expected", reasoning: "matched" }
      @tool_calls_by_name = {}
    end

    def set_criterion_result(name, satisfied, reasoning = nil)
      @criterion_results[name.to_sym] = {
        satisfied: satisfied,
        reasoning: reasoning || (satisfied ? "Passed" : "Failed")
      }
    end

    def set_grounding_result(grounded, violations = [])
      @grounding_result = { grounded: grounded, violations: violations }
    end

    def set_forbidden_claims_result(violated, claims_found = [])
      @forbidden_claims_result = { violated: violated, claims_found: claims_found }
    end

    def set_intent_result(matches, observed_intent = nil, reasoning = nil)
      @intent_result = {
        matches:         matches,
        observed_intent: observed_intent || "observed",
        reasoning:       reasoning || "reason"
      }
    end

    def set_tool_calls(name, calls)
      @tool_calls_by_name[name.to_sym] = calls
    end

    def evaluate_criterion(name)
      @criterion_results[name.to_sym] || { satisfied: true, reasoning: "Default pass" }
    end

    def set_adhoc_criterion_result(description, satisfied, reasoning = nil)
      @adhoc_criterion_results ||= {}
      @adhoc_criterion_results[description] = {
        satisfied: satisfied,
        reasoning: reasoning || (satisfied ? "Adhoc passed" : "Adhoc failed")
      }
    end

    def evaluate_adhoc_criterion(description)
      @adhoc_criterion_results ||= {}
      @adhoc_criterion_results[description] || { satisfied: true, reasoning: "Default adhoc pass" }
    end

    def check_grounding(_claim_types, from_tools: [])
      @grounding_result
    end

    def check_forbidden_claims(_claim_types)
      @forbidden_claims_result
    end

    def check_intent(_description)
      @intent_result
    end

    def tool_calls(name = nil)
      if name
        @tool_calls_by_name[name.to_sym] || []
      else
        @tool_calls_by_name.values.flatten
      end
    end
  end

  # Agent proxy that holds a runner reference
  # Mimics the real AgentProxy interface
  class MockAgentProxy
    attr_reader :runner

    def initialize(runner)
      @runner = runner
    end

    def tool_calls
      @runner.tool_calls
    end

    def current_topic
      @runner.current_topic
    end

    def current_turn
      @runner.current_turn
    end

    # Delegate to runner.conversation (matches real AgentProxy)
    def conversation
      @runner.conversation
    end

    # Unified criterion evaluation - mimics AgentProxy#evaluate_criterion
    # Now accepts Criterion objects (from the refactored SatisfyMatcher)
    def evaluate_criterion(criterion)
      turn = current_turn
      return { satisfied: false, reasoning: "No turn to evaluate" } unless turn

      # Handle Criterion objects from the new Criterion class
      if criterion.is_a?(RSpec::Agents::Criterion)
        evaluatable = criterion.evaluatable
        case evaluatable
        when Proc
          result = evaluatable.call(turn)
          { satisfied: !!result, reasoning: result ? "Lambda passed" : "Lambda failed" }
        when Symbol
          @runner.evaluate_criterion(evaluatable)
        when String
          @runner.evaluate_adhoc_criterion(evaluatable)
        else
          { satisfied: false, reasoning: "Unknown criterion type" }
        end
      else
        # Legacy support for raw values (backwards compatibility)
        case criterion
        when Proc
          result = criterion.call(turn)
          { satisfied: !!result, reasoning: result ? "Lambda passed" : "Lambda failed" }
        when Symbol
          @runner.evaluate_criterion(criterion)
        when String
          @runner.evaluate_adhoc_criterion(criterion)
        else
          { satisfied: false, reasoning: "Unknown criterion type" }
        end
      end
    end
  end

  def build_turn(user_message:, agent_text:, tool_calls: [])
    response = RSpec::Agents::AgentResponse.new(text: agent_text, tool_calls: tool_calls)
    RSpec::Agents::Turn.new(user_message, response)
  end

  let(:runner) { MockRunner.new }
  let(:agent_proxy) { MockAgentProxy.new(runner) }

  describe RSpec::Agents::Matchers::SatisfyMatcher do
    before do
      runner.current_turn = build_turn(
        user_message: "Hello",
        agent_text:   "Hi there! How can I help you today?"
      )
    end

    describe "with named criteria" do
      it "passes when criterion is satisfied" do
        runner.set_criterion_result(:friendly, true, "Agent was friendly")

        matcher = satisfy(:friendly)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when criterion is not satisfied" do
        runner.set_criterion_result(:friendly, false, "Agent was rude")

        matcher = satisfy(:friendly)
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "evaluates multiple criteria" do
        runner.set_criterion_result(:friendly, true)
        runner.set_criterion_result(:helpful, true)

        matcher = satisfy(:friendly, :helpful)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when any criterion fails" do
        runner.set_criterion_result(:friendly, true)
        runner.set_criterion_result(:helpful, false, "Not helpful")

        matcher = satisfy(:friendly, :helpful)
        expect(matcher.matches?(agent_proxy)).to be false
      end
    end

    describe "with adhoc criterion (string description)" do
      it "evaluates string description via LLM judge" do
        runner.set_adhoc_criterion_result("Der Agent fragt nach Details", true, "Agent asked for details")

        matcher = satisfy("Der Agent fragt nach Details")
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when adhoc criterion is not satisfied" do
        runner.set_adhoc_criterion_result("The agent shows a form", false, "No form was displayed")

        matcher = satisfy("The agent shows a form")
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "can evaluate multiple adhoc criteria" do
        runner.set_adhoc_criterion_result("Response is concise", true)
        runner.set_adhoc_criterion_result("Response is helpful", true)

        matcher = satisfy("Response is concise", "Response is helpful")
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when any adhoc criterion fails" do
        runner.set_adhoc_criterion_result("Response is concise", true)
        runner.set_adhoc_criterion_result("Response is helpful", false, "Not helpful")

        matcher = satisfy("Response is concise", "Response is helpful")
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "can mix named criteria and adhoc criteria" do
        runner.set_criterion_result(:friendly, true)
        runner.set_adhoc_criterion_result("The agent acknowledges the request", true)

        matcher = satisfy(:friendly, "The agent acknowledges the request")
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "can mix adhoc criteria and lambdas" do
        runner.set_adhoc_criterion_result("Response mentions booking", true)

        matcher = satisfy(
          "Response mentions booking",
          ->(turn) { turn.agent_response.text.include?("Hi") }
        )
        expect(matcher.matches?(agent_proxy)).to be true
      end
    end

    describe "with lambda criteria" do
      it "evaluates anonymous lambda directly" do
        matcher = satisfy(->(turn) { turn.agent_response.text.include?("Hi") })
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when lambda returns false" do
        matcher = satisfy(->(turn) { turn.agent_response.text.include?("goodbye") })
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "evaluates named lambda" do
        matcher = satisfy(:concise, ->(turn) { turn.agent_response.text.length < 100 })
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when named lambda returns false" do
        matcher = satisfy(:concise, ->(turn) { turn.agent_response.text.length < 5 })
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "mixes named criteria and lambdas" do
        runner.set_criterion_result(:friendly, true)

        matcher = satisfy(:friendly, ->(turn) { turn.agent_response.text.length > 10 })
        expect(matcher.matches?(agent_proxy)).to be true
      end
    end

    describe "#failure_message" do
      it "provides descriptive failure message" do
        runner.set_criterion_result(:friendly, false, "Agent was too formal")

        matcher = satisfy(:friendly)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("Expected agent to satisfy criteria")
        expect(matcher.failure_message).to include("friendly")
        expect(matcher.failure_message).to include("too formal")
      end

      it "includes adhoc criterion description in failure message" do
        runner.set_adhoc_criterion_result("Der Agent zeigt das Formular an", false, "Kein Formular angezeigt")

        matcher = satisfy("Der Agent zeigt das Formular an")
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("Der Agent zeigt das Formular an")
        expect(matcher.failure_message).to include("Kein Formular angezeigt")
      end
    end

    describe "#failure_message_when_negated" do
      it "provides negated failure message" do
        runner.set_criterion_result(:friendly, true)

        matcher = satisfy(:friendly)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message_when_negated).to include("Expected agent not to satisfy")
      end
    end

    it "returns false when no runner available" do
      proxy_without_runner = Object.new

      matcher = satisfy(:friendly)
      expect(matcher.matches?(proxy_without_runner)).to be false
    end
  end

  describe RSpec::Agents::Matchers::CallToolMatcher do
    describe "basic matching" do
      it "matches when tool is called" do
        tool_call = RSpec::Agents::ToolCall.new(name: :search_venues, arguments: {})
        runner.set_tool_calls(:search_venues, [tool_call])

        matcher = call_tool(:search_venues)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when tool is not called" do
        runner.set_tool_calls(:other_tool, [RSpec::Agents::ToolCall.new(name: :other_tool)])

        matcher = call_tool(:search_venues)
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "accepts string tool names" do
        tool_call = RSpec::Agents::ToolCall.new(name: :search_venues, arguments: {})
        runner.set_tool_calls(:search_venues, [tool_call])

        matcher = call_tool("search_venues")
        expect(matcher.matches?(agent_proxy)).to be true
      end
    end

    describe ".with() parameter matching" do
      let(:tool_call) do
        RSpec::Agents::ToolCall.new(
          name:      :book_room,
          arguments: { room: "Blue Room", time: "14:00", capacity: 20 }
        )
      end

      before do
        runner.set_tool_calls(:book_room, [tool_call])
      end

      it "matches with exact values" do
        matcher = call_tool(:book_room).with(room: "Blue Room")
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when exact value doesn't match" do
        matcher = call_tool(:book_room).with(room: "Red Room")
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "matches with Regexp" do
        matcher = call_tool(:book_room).with(time: /14:00|2:00\s*pm/i)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when Regexp doesn't match" do
        matcher = call_tool(:book_room).with(time: /15:00/)
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "matches with Proc" do
        matcher = call_tool(:book_room).with(capacity: ->(v) { v >= 10 })
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when Proc returns false" do
        matcher = call_tool(:book_room).with(capacity: ->(v) { v >= 50 })
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "matches with RSpec matchers" do
        matcher = call_tool(:book_room).with(capacity: be >= 10)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "matches multiple params" do
        matcher = call_tool(:book_room).with(room: "Blue Room", capacity: 20)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when any param doesn't match" do
        matcher = call_tool(:book_room).with(room: "Blue Room", capacity: 100)
        expect(matcher.matches?(agent_proxy)).to be false
      end
    end

    describe "#failure_message" do
      it "reports no tools called" do
        matcher = call_tool(:search_venues)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("no tools were called")
      end

      it "reports which tools were called" do
        runner.set_tool_calls(:other_tool, [RSpec::Agents::ToolCall.new(name: :other_tool)])

        matcher = call_tool(:search_venues)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("other_tool")
      end

      it "reports param mismatch" do
        tool_call = RSpec::Agents::ToolCall.new(name: :book_room, arguments: { room: "Red Room" })
        runner.set_tool_calls(:book_room, [tool_call])

        matcher = call_tool(:book_room).with(room: "Blue Room")
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("Blue Room")
        expect(matcher.failure_message).to include("Red Room")
      end
    end

    describe "#failure_message_when_negated" do
      it "provides negated failure message" do
        tool_call = RSpec::Agents::ToolCall.new(name: :search_venues)
        runner.set_tool_calls(:search_venues, [tool_call])

        matcher = call_tool(:search_venues)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message_when_negated).to include("Expected agent not to call tool")
      end
    end
  end

  describe RSpec::Agents::Matchers::BeGroundedInMatcher do
    it "verifies claims are grounded via runner" do
      runner.set_grounding_result(true)

      matcher = be_grounded_in(:venues, :pricing)
      expect(matcher.matches?(agent_proxy)).to be true
    end

    it "fails when claims are not grounded" do
      runner.set_grounding_result(false, ["Price not found in tool results"])

      matcher = be_grounded_in(:pricing)
      expect(matcher.matches?(agent_proxy)).to be false
    end

    it "accepts from_tools parameter" do
      runner.set_grounding_result(true)

      matcher = be_grounded_in(:venues, from_tools: [:search_venues])
      expect(matcher.matches?(agent_proxy)).to be true
    end

    describe "#failure_message" do
      it "includes violations in failure message" do
        runner.set_grounding_result(false, ["Price was hallucinated", "Venue name not in results"])

        matcher = be_grounded_in(:venues, :pricing)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("Price was hallucinated")
        expect(matcher.failure_message).to include("Venue name not in results")
      end
    end

    it "returns false when no runner available" do
      proxy_without_runner = Object.new

      matcher = be_grounded_in(:venues)
      expect(matcher.matches?(proxy_without_runner)).to be false
    end
  end

  describe RSpec::Agents::Matchers::ClaimMatcher do
    it "detects forbidden claims" do
      runner.set_forbidden_claims_result(true, [{ "claim" => "available on Monday" }])

      matcher = claim(:availability)
      expect(matcher.matches?(agent_proxy)).to be true
    end

    it "passes when no claims found" do
      runner.set_forbidden_claims_result(false, [])

      matcher = claim(:availability)
      expect(matcher.matches?(agent_proxy)).to be false
    end

    describe "#failure_message" do
      it "reports no claims found" do
        runner.set_forbidden_claims_result(false, [])

        matcher = claim(:availability)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("none were found")
      end
    end

    describe "#failure_message_when_negated" do
      it "reports found claims" do
        runner.set_forbidden_claims_result(true, [{ "claim" => "available Monday" }])

        matcher = claim(:availability)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message_when_negated).to include("available Monday")
      end
    end

    it "returns false when no runner available" do
      proxy_without_runner = Object.new

      matcher = claim(:availability)
      expect(matcher.matches?(proxy_without_runner)).to be false
    end
  end

  describe RSpec::Agents::Matchers::HaveIntentMatcher do
    it "verifies agent intent via runner" do
      runner.set_intent_result(true, "gathering requirements")

      matcher = have_intent(:gather_requirements)
      expect(matcher.matches?(agent_proxy)).to be true
    end

    it "fails when intent doesn't match" do
      runner.set_intent_result(false, "small talk", "Agent was making small talk")

      matcher = have_intent(:gather_requirements)
      expect(matcher.matches?(agent_proxy)).to be false
    end

    it "uses described_as when provided" do
      runner.set_intent_result(true)

      matcher = have_intent(:gather_requirements, described_as: "Ask about dates and capacity")
      expect(matcher.matches?(agent_proxy)).to be true
    end

    it "converts intent name to description when described_as not provided" do
      runner.set_intent_result(true)

      matcher = have_intent(:gather_requirements)
      # Should use "gather requirements" as the description
      expect(matcher.matches?(agent_proxy)).to be true
    end

    describe "#failure_message" do
      it "includes observed intent and reasoning" do
        runner.set_intent_result(false, "selling products", "Agent tried to upsell")

        matcher = have_intent(:gather_requirements)
        matcher.matches?(agent_proxy)

        message = matcher.failure_message
        expect(message).to include("gather requirements")
        expect(message).to include("selling products")
        expect(message).to include("upsell")
      end
    end

    it "returns false when no runner available" do
      proxy_without_runner = Object.new

      matcher = have_intent(:gather_requirements)
      expect(matcher.matches?(proxy_without_runner)).to be false
    end
  end

  describe RSpec::Agents::Matchers::BeInTopicMatcher do
    it "checks current topic via agent proxy" do
      runner.current_topic = :greeting

      matcher = be_in_topic(:greeting)
      expect(matcher.matches?(agent_proxy)).to be true
    end

    it "fails when in different topic" do
      runner.current_topic = :gathering

      matcher = be_in_topic(:greeting)
      expect(matcher.matches?(agent_proxy)).to be false
    end

    it "accepts string topic names" do
      runner.current_topic = :greeting

      matcher = be_in_topic("greeting")
      expect(matcher.matches?(agent_proxy)).to be true
    end

    it "checks via in_topic? method when available" do
      proxy_with_in_topic = Object.new
      def proxy_with_in_topic.in_topic?(name)
        name == :greeting
      end

      matcher = be_in_topic(:greeting)
      expect(matcher.matches?(proxy_with_in_topic)).to be true
    end

    describe "#failure_message" do
      it "reports expected and actual topic" do
        runner.current_topic = :gathering

        matcher = be_in_topic(:greeting)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("greeting")
        expect(matcher.failure_message).to include("gathering")
      end

      it "handles nil topic" do
        runner.current_topic = nil

        matcher = be_in_topic(:greeting)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("none")
      end
    end

    describe "#failure_message_when_negated" do
      it "provides negated failure message" do
        runner.current_topic = :greeting

        matcher = be_in_topic(:greeting)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message_when_negated).to include("Expected agent not to be in topic")
      end
    end
  end

  describe RSpec::Agents::Matchers::HaveReachedTopicMatcher do
    # Mock conversation for topic history testing
    class MockConversation
      attr_accessor :topic_history

      def initialize(topic_history = [])
        @topic_history = topic_history
      end
    end

    let(:conversation) { MockConversation.new }

    before do
      # Add conversation accessor to MockRunner
      runner.instance_variable_set(:@conversation, conversation)
      def runner.conversation
        @conversation
      end
    end

    describe "basic matching" do
      it "matches when topic was visited" do
        conversation.topic_history = [
          { topic: :greeting, turns: [] },
          { topic: :gathering_details, turns: [] },
          { topic: :confirmation, turns: [] }
        ]

        matcher = have_reached_topic(:confirmation)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when topic was never visited" do
        conversation.topic_history = [
          { topic: :greeting, turns: [] },
          { topic: :gathering_details, turns: [] }
        ]

        matcher = have_reached_topic(:confirmation)
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "accepts string topic names" do
        conversation.topic_history = [
          { topic: :greeting, turns: [] }
        ]

        matcher = have_reached_topic("greeting")
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "handles empty topic history" do
        conversation.topic_history = []

        matcher = have_reached_topic(:greeting)
        expect(matcher.matches?(agent_proxy)).to be false
      end
    end

    describe "#failure_message" do
      it "reports visited topics" do
        conversation.topic_history = [
          { topic: :greeting, turns: [] },
          { topic: :gathering_details, turns: [] }
        ]

        matcher = have_reached_topic(:confirmation)
        matcher.matches?(agent_proxy)

        message = matcher.failure_message
        expect(message).to include("confirmation")
        expect(message).to include("greeting")
        expect(message).to include("gathering_details")
      end

      it "handles empty topic history" do
        conversation.topic_history = []

        matcher = have_reached_topic(:confirmation)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("no topics were visited")
      end
    end

    describe "#failure_message_when_negated" do
      it "provides negated failure message" do
        conversation.topic_history = [{ topic: :greeting, turns: [] }]

        matcher = have_reached_topic(:greeting)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message_when_negated).to include("not to reach topic")
      end
    end

    it "returns false when no runner available" do
      proxy_without_runner = Object.new

      matcher = have_reached_topic(:greeting)
      expect(matcher.matches?(proxy_without_runner)).to be false
    end
  end

  describe RSpec::Agents::Matchers::HaveToolCallMatcher do
    # Mock conversation for tool call testing
    class MockConversationWithToolCalls
      attr_accessor :tool_calls

      def initialize(tool_calls = [])
        @tool_calls = tool_calls
      end

      def find_tool_calls(name, params: nil)
        calls = @tool_calls.select { |tc| tc.name == name }
        return calls if params.nil? || params.empty?

        # Filter by params - reuse existing matching logic
        calls.select do |tc|
          params.all? do |key, expected_value|
            actual_value = tc.argument(key)
            case expected_value
            when Regexp
              expected_value.match?(actual_value.to_s)
            when Proc
              expected_value.call(actual_value)
            when RSpec::Matchers::BuiltIn::BaseMatcher
              expected_value.matches?(actual_value)
            else
              actual_value == expected_value
            end
          end
        end
      end
    end

    let(:conversation_with_tools) { MockConversationWithToolCalls.new }

    before do
      runner.instance_variable_set(:@conversation, conversation_with_tools)
      def runner.conversation
        @conversation
      end
    end

    describe "basic matching" do
      it "matches when tool was called" do
        tool_call = RSpec::Agents::ToolCall.new(name: :book_venue, arguments: {})
        conversation_with_tools.tool_calls = [tool_call]

        matcher = have_tool_call(:book_venue)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when tool was never called" do
        tool_call = RSpec::Agents::ToolCall.new(name: :search_venue, arguments: {})
        conversation_with_tools.tool_calls = [tool_call]

        matcher = have_tool_call(:book_venue)
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "accepts string tool names" do
        tool_call = RSpec::Agents::ToolCall.new(name: :book_venue, arguments: {})
        conversation_with_tools.tool_calls = [tool_call]

        matcher = have_tool_call("book_venue")
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "handles empty tool calls" do
        conversation_with_tools.tool_calls = []

        matcher = have_tool_call(:book_venue)
        expect(matcher.matches?(agent_proxy)).to be false
      end
    end

    describe "parameter matching" do
      let(:tool_call) do
        RSpec::Agents::ToolCall.new(
          name:      :book_venue,
          arguments: { city: "Stuttgart", capacity: 50, budget: 30000 }
        )
      end

      before do
        conversation_with_tools.tool_calls = [tool_call]
      end

      it "matches with exact parameter values" do
        matcher = have_tool_call(:book_venue, city: "Stuttgart")
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when parameter value doesn't match" do
        matcher = have_tool_call(:book_venue, city: "Munich")
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "matches with Regexp" do
        matcher = have_tool_call(:book_venue, city: /stutt/i)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "matches with Proc" do
        matcher = have_tool_call(:book_venue, capacity: ->(v) { v >= 40 })
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "matches with RSpec matchers" do
        matcher = have_tool_call(:book_venue, capacity: be >= 40)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "matches multiple parameters" do
        matcher = have_tool_call(:book_venue, city: "Stuttgart", capacity: 50)
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when any parameter doesn't match" do
        matcher = have_tool_call(:book_venue, city: "Stuttgart", capacity: 100)
        expect(matcher.matches?(agent_proxy)).to be false
      end
    end

    describe "multiple tool calls" do
      it "matches when any call has matching parameters" do
        call1 = RSpec::Agents::ToolCall.new(name: :book_venue, arguments: { city: "Munich" })
        call2 = RSpec::Agents::ToolCall.new(name: :book_venue, arguments: { city: "Stuttgart" })
        conversation_with_tools.tool_calls = [call1, call2]

        matcher = have_tool_call(:book_venue, city: "Stuttgart")
        expect(matcher.matches?(agent_proxy)).to be true
      end
    end

    describe "#failure_message" do
      it "reports tool was never called" do
        conversation_with_tools.tool_calls = []

        matcher = have_tool_call(:book_venue)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("never called")
      end

      it "reports parameter mismatch" do
        tool_call = RSpec::Agents::ToolCall.new(
          name:      :book_venue,
          arguments: { city: "Munich" }
        )
        conversation_with_tools.tool_calls = [tool_call]

        matcher = have_tool_call(:book_venue, city: "Stuttgart")
        matcher.matches?(agent_proxy)

        message = matcher.failure_message
        expect(message).to include("Stuttgart")
        expect(message).to include("Munich")
      end
    end

    describe "#failure_message_when_negated" do
      it "provides negated failure message without params" do
        tool_call = RSpec::Agents::ToolCall.new(name: :book_venue, arguments: {})
        conversation_with_tools.tool_calls = [tool_call]

        matcher = have_tool_call(:book_venue)
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message_when_negated).to include("not to have tool call")
      end

      it "provides negated failure message with params" do
        tool_call = RSpec::Agents::ToolCall.new(
          name:      :book_venue,
          arguments: { city: "Stuttgart" }
        )
        conversation_with_tools.tool_calls = [tool_call]

        matcher = have_tool_call(:book_venue, city: "Stuttgart")
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message_when_negated).to include("not to have tool call")
        expect(matcher.failure_message_when_negated).to include("Stuttgart")
      end
    end

    it "returns false when no runner available" do
      proxy_without_runner = Object.new

      matcher = have_tool_call(:book_venue)
      expect(matcher.matches?(proxy_without_runner)).to be false
    end

    describe "with Conversation directly" do
      it "matches when passed a Conversation object with tool calls" do
        conversation = RSpec::Agents::Conversation.new
        response = RSpec::Agents::AgentResponse.new(
          text:       "Done!",
          tool_calls: [RSpec::Agents::ToolCall.new(name: :book_venue, arguments: { city: "Stuttgart" })]
        )
        conversation.add_user_message("Book a venue")
        conversation.add_agent_response(response)

        matcher = have_tool_call(:book_venue)
        expect(matcher.matches?(conversation)).to be true
      end

      it "fails when Conversation has no matching tool calls" do
        conversation = RSpec::Agents::Conversation.new
        response = RSpec::Agents::AgentResponse.new(
          text:       "Done!",
          tool_calls: [RSpec::Agents::ToolCall.new(name: :search_venue, arguments: {})]
        )
        conversation.add_user_message("Book a venue")
        conversation.add_agent_response(response)

        matcher = have_tool_call(:book_venue)
        expect(matcher.matches?(conversation)).to be false
      end

      it "matches with parameters when passed a Conversation object" do
        conversation = RSpec::Agents::Conversation.new
        response = RSpec::Agents::AgentResponse.new(
          text:       "Done!",
          tool_calls: [RSpec::Agents::ToolCall.new(name: :book_venue, arguments: { city: "Stuttgart" })]
        )
        conversation.add_user_message("Book a venue")
        conversation.add_agent_response(response)

        matcher = have_tool_call(:book_venue, city: "Stuttgart")
        expect(matcher.matches?(conversation)).to be true
      end

      it "provides correct failure message when passed a Conversation object" do
        conversation = RSpec::Agents::Conversation.new
        response = RSpec::Agents::AgentResponse.new(
          text:       "Done!",
          tool_calls: []
        )
        conversation.add_user_message("Book a venue")
        conversation.add_agent_response(response)

        matcher = have_tool_call(:book_venue)
        matcher.matches?(conversation)

        expect(matcher.failure_message).to include("never called")
      end
    end
  end

  describe RSpec::Agents::Matchers::HaveAchievedStatedGoalMatcher do
    # Mock conversation, judge, and simulator config
    class MockJudge
      attr_accessor :goal_evaluation_result

      def initialize
        @goal_evaluation_result = { achieved: true, reasoning: "Goal was achieved" }
      end

      def evaluate_goal_achievement(_goal_description, _conversation)
        @goal_evaluation_result
      end
    end

    class MockSimulatorConfig
      attr_accessor :goal

      def initialize(goal = nil)
        @goal = goal
      end
    end

    let(:judge) { MockJudge.new }
    let(:simulator_config) { MockSimulatorConfig.new("Find a venue for 50 people") }
    let(:conversation_with_tools) { MockConversationWithToolCalls.new }

    before do
      # Setup runner with judge and simulator config
      runner.instance_variable_set(:@conversation, conversation_with_tools)
      runner.instance_variable_set(:@judge, judge)
      runner.instance_variable_set(:@simulator_config, simulator_config)

      def runner.conversation
        @conversation
      end

      def runner.judge
        @judge
      end

      def runner.simulator_config
        @simulator_config
      end
    end

    describe "basic matching" do
      it "matches when goal was achieved" do
        judge.goal_evaluation_result = { achieved: true, reasoning: "All requirements met" }

        matcher = have_achieved_stated_goal
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when goal was not achieved" do
        judge.goal_evaluation_result = { achieved: false, reasoning: "Conversation ended prematurely" }

        matcher = have_achieved_stated_goal
        expect(matcher.matches?(agent_proxy)).to be false
      end

      it "fails when no goal was specified" do
        simulator_config.goal = nil

        matcher = have_achieved_stated_goal
        expect(matcher.matches?(agent_proxy)).to be false
      end
    end

    describe "#failure_message" do
      it "includes goal and reasoning when not achieved" do
        judge.goal_evaluation_result = { achieved: false, reasoning: "Missing required information" }

        matcher = have_achieved_stated_goal
        matcher.matches?(agent_proxy)

        message = matcher.failure_message
        expect(message).to include("Find a venue for 50 people")
        expect(message).to include("Missing required information")
      end

      it "provides error message when no goal specified" do
        simulator_config.goal = nil

        matcher = have_achieved_stated_goal
        matcher.matches?(agent_proxy)

        expect(matcher.failure_message).to include("No goal was specified")
      end
    end

    describe "#failure_message_when_negated" do
      it "provides negated failure message" do
        judge.goal_evaluation_result = { achieved: true, reasoning: "Goal completed" }

        matcher = have_achieved_stated_goal
        matcher.matches?(agent_proxy)

        message = matcher.failure_message_when_negated
        expect(message).to include("not to achieve")
        expect(message).to include("Find a venue for 50 people")
      end
    end

    it "returns false when no runner available" do
      proxy_without_runner = Object.new

      matcher = have_achieved_stated_goal
      expect(matcher.matches?(proxy_without_runner)).to be false
    end
  end

  describe RSpec::Agents::Matchers::HaveAchievedGoalMatcher do
    let(:judge) { MockJudge.new }
    let(:conversation_with_tools) { MockConversationWithToolCalls.new }

    before do
      runner.instance_variable_set(:@conversation, conversation_with_tools)
      runner.instance_variable_set(:@judge, judge)

      def runner.conversation
        @conversation
      end

      def runner.judge
        @judge
      end
    end

    describe "basic matching" do
      it "matches when custom goal was achieved" do
        judge.goal_evaluation_result = { achieved: true, reasoning: "Custom goal met" }

        matcher = have_achieved_goal("User received venue options under budget")
        expect(matcher.matches?(agent_proxy)).to be true
      end

      it "fails when custom goal was not achieved" do
        judge.goal_evaluation_result = { achieved: false, reasoning: "Budget requirements not met" }

        matcher = have_achieved_goal("User received venue options under budget")
        expect(matcher.matches?(agent_proxy)).to be false
      end
    end

    describe "#failure_message" do
      it "includes custom goal and reasoning" do
        judge.goal_evaluation_result = { achieved: false, reasoning: "Options exceeded budget" }

        matcher = have_achieved_goal("User received venue options under budget")
        matcher.matches?(agent_proxy)

        message = matcher.failure_message
        expect(message).to include("User received venue options under budget")
        expect(message).to include("Options exceeded budget")
      end
    end

    describe "#failure_message_when_negated" do
      it "provides negated failure message" do
        judge.goal_evaluation_result = { achieved: true, reasoning: "Goal met" }

        matcher = have_achieved_goal("User received venue options under budget")
        matcher.matches?(agent_proxy)

        message = matcher.failure_message_when_negated
        expect(message).to include("not to achieve")
        expect(message).to include("User received venue options under budget")
      end
    end

    it "returns false when no runner available" do
      proxy_without_runner = Object.new

      matcher = have_achieved_goal("Some goal")
      expect(matcher.matches?(proxy_without_runner)).to be false
    end
  end

  describe "DSL integration" do
    # Test that the matchers work correctly when included as a module
    it "provides satisfy matcher" do
      expect(respond_to?(:satisfy)).to be true
    end

    it "provides call_tool matcher" do
      expect(respond_to?(:call_tool)).to be true
    end

    it "provides be_grounded_in matcher" do
      expect(respond_to?(:be_grounded_in)).to be true
    end

    it "provides claim matcher" do
      expect(respond_to?(:claim)).to be true
    end

    it "provides have_intent matcher" do
      expect(respond_to?(:have_intent)).to be true
    end

    it "provides be_in_topic matcher" do
      expect(respond_to?(:be_in_topic)).to be true
    end

    it "provides have_reached_topic matcher" do
      expect(respond_to?(:have_reached_topic)).to be true
    end

    it "provides have_tool_call matcher" do
      expect(respond_to?(:have_tool_call)).to be true
    end

    it "provides have_achieved_stated_goal matcher" do
      expect(respond_to?(:have_achieved_stated_goal)).to be true
    end

    it "provides have_achieved_goal matcher" do
      expect(respond_to?(:have_achieved_goal)).to be true
    end
  end
end
