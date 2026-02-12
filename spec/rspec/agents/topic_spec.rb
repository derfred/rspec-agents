require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::Topic do
  describe "#initialize" do
    it "requires a name" do
      topic = described_class.new(:greeting)
      expect(topic.name).to eq(:greeting)
    end

    it "converts string name to symbol" do
      topic = described_class.new("greeting")
      expect(topic.name).to eq(:greeting)
    end

    it "evaluates DSL block" do
      topic = described_class.new(:greeting) do
        characteristic "Initial contact phase"
        agent_intent "Welcome the user"
      end

      expect(topic.characteristic_text).to eq("Initial contact phase")
      expect(topic.agent_intent_text).to eq("Welcome the user")
    end

    it "initializes with empty triggers" do
      topic = described_class.new(:greeting)
      expect(topic.triggers.empty?).to be true
    end

    it "initializes with empty invariants" do
      topic = described_class.new(:greeting)
      expect(topic.invariants.empty?).to be true
    end

    it "initializes with empty successors" do
      topic = described_class.new(:greeting)
      expect(topic.successors).to eq([])
    end
  end

  describe "#characteristic" do
    it "sets characteristic text" do
      topic = described_class.new(:greeting) do
        characteristic "  The agent greets the user  "
      end
      expect(topic.characteristic_text).to eq("The agent greets the user")
    end
  end

  describe "#agent_intent" do
    it "sets agent intent text" do
      topic = described_class.new(:gathering) do
        agent_intent "  Collect event requirements  "
      end
      expect(topic.agent_intent_text).to eq("Collect event requirements")
    end
  end

  describe "#triggers" do
    it "defines triggers via block" do
      topic = described_class.new(:presenting) do
        triggers do
          on_tool_call :search_venues
          on_response_match /here are some options/i
        end
      end

      expect(topic.triggers.count).to eq(2)
    end

    it "returns triggers when called without block" do
      topic = described_class.new(:greeting)
      expect(topic.triggers).to be_a(RSpec::Agents::Triggers)
    end
  end

  describe "#expect_agent" do
    it "adds quality expectations with to_satisfy" do
      topic = described_class.new(:greeting) do
        expect_agent to_satisfy: [:friendly, :helpful]
      end

      expect(topic.invariants).not_to be_empty
    end

    it "adds match expectations with to_match" do
      topic = described_class.new(:greeting) do
        expect_agent to_match: /hello|hi/i
      end

      expect(topic.invariants).not_to be_empty
    end

    it "adds no_match expectations with not_to_match" do
      topic = described_class.new(:greeting) do
        expect_agent not_to_match: /error|sorry/i
      end

      expect(topic.invariants).not_to be_empty
    end

    it "combines multiple expectation types" do
      topic = described_class.new(:greeting) do
        expect_agent to_satisfy: [:friendly], to_match: /hello/i, not_to_match: /error/i
      end

      expect(topic.invariants).not_to be_empty
    end
  end

  describe "#expect_grounding" do
    it "adds grounding expectation" do
      topic = described_class.new(:presenting) do
        expect_grounding :venues, :pricing, from_tools: [:search_suppliers]
      end

      expect(topic.invariants).not_to be_empty
    end
  end

  describe "#forbid_claims" do
    it "adds forbidden claims" do
      topic = described_class.new(:gathering) do
        forbid_claims :availability, :pricing
      end

      expect(topic.invariants).not_to be_empty
    end
  end

  describe "#expect_tool_call" do
    it "adds tool call expectation" do
      topic = described_class.new(:presenting) do
        expect_tool_call :search_suppliers
      end

      expect(topic.invariants).not_to be_empty
    end
  end

  describe "#forbid_tool_call" do
    it "adds forbidden tool call" do
      topic = described_class.new(:gathering) do
        forbid_tool_call :book_venue
      end

      expect(topic.invariants).not_to be_empty
    end
  end

  describe "#expect (custom)" do
    it "adds custom expectation with block" do
      topic = described_class.new(:presenting) do
        expect "Response under 500 chars" do |turn, conversation|
          turn.agent_response.text.length <= 500
        end
      end

      expect(topic.invariants).not_to be_empty
    end
  end

  describe "#trigger_matches?" do
    let(:turn) do
      double("Turn",
        agent_response: RSpec::Agents::AgentResponse.new(
          text:       "Found venues",
          tool_calls: [RSpec::Agents::ToolCall.new(name: :search_venues)]
        ),
        user_message:   "Find venues"
      )
    end

    let(:conversation) { double("Conversation") }

    it "returns true when trigger matches" do
      topic = described_class.new(:presenting) do
        triggers { on_tool_call :search_venues }
      end

      expect(topic.trigger_matches?(turn, conversation)).to be true
    end

    it "returns false when no trigger matches" do
      topic = described_class.new(:presenting) do
        triggers { on_tool_call :book_venue }
      end

      expect(topic.trigger_matches?(turn, conversation)).to be false
    end
  end

  describe "#evaluate_invariants" do
    let(:turn) do
      double("Turn",
        agent_response: RSpec::Agents::AgentResponse.new(
          text:       "Hello! How can I help you today?",
          tool_calls: []
        )
      )
    end
    let(:conversation) { double("Conversation") }
    let(:judge) { double("Judge") }

    it "evaluates pattern matching invariants" do
      topic = described_class.new(:greeting) do
        expect_agent to_match: /hello/i
        expect_agent not_to_match: /error/i
      end

      results = topic.evaluate_invariants([turn], conversation, judge)

      expect(results.failures).to be_empty
    end

    it "fails when pattern not matched" do
      topic = described_class.new(:greeting) do
        expect_agent to_match: /goodbye/i
      end

      results = topic.evaluate_invariants([turn], conversation, judge)

      expect(results.failures).not_to be_empty
      expect(results.failures.first[:failure_message]).to include("No response matched")
    end

    it "fails when forbidden pattern matched" do
      turn_with_error = double("Turn",
        agent_response: RSpec::Agents::AgentResponse.new(text: "Sorry, an error occurred")
      )

      topic = described_class.new(:greeting) do
        expect_agent not_to_match: /error/i
      end

      results = topic.evaluate_invariants([turn_with_error], conversation, judge)

      expect(results.failures).not_to be_empty
      expect(results.failures.first[:failure_message]).to include("forbidden pattern")
    end

    it "evaluates tool call expectations" do
      turn_with_tool = double("Turn",
        agent_response: RSpec::Agents::AgentResponse.new(
          text:       "Searching...",
          tool_calls: [RSpec::Agents::ToolCall.new(name: :search_venues)]
        )
      )

      topic = described_class.new(:presenting) do
        expect_tool_call :search_venues
        forbid_tool_call :book_venue
      end

      results = topic.evaluate_invariants([turn_with_tool], conversation, judge)

      expect(results.failures).to be_empty
    end

    it "fails when expected tool not called" do
      topic = described_class.new(:presenting) do
        expect_tool_call :search_venues
      end

      results = topic.evaluate_invariants([turn], conversation, judge)

      expect(results.failures).not_to be_empty
      expect(results.failures.first[:failure_message]).to include("search_venues")
    end

    it "fails when forbidden tool called" do
      turn_with_forbidden = double("Turn",
        agent_response: RSpec::Agents::AgentResponse.new(
          text:       "Booking...",
          tool_calls: [RSpec::Agents::ToolCall.new(name: :book_venue)]
        )
      )

      topic = described_class.new(:gathering) do
        forbid_tool_call :book_venue
      end

      results = topic.evaluate_invariants([turn_with_forbidden], conversation, judge)

      expect(results.failures).not_to be_empty
      expect(results.failures.first[:failure_message]).to include("Forbidden tool")
    end

    it "evaluates custom expectations" do
      topic = described_class.new(:presenting) do
        expect "Response under 100 chars" do |t, c|
          t.agent_response.text.length <= 100
        end
      end

      results = topic.evaluate_invariants([turn], conversation, judge)

      expect(results.failures).to be_empty
    end

    it "queues LLM-based expectations as pending" do
      topic = described_class.new(:greeting) do
        expect_agent to_satisfy: [:friendly]
        expect_grounding :venues, from_tools: [:search]
        forbid_claims :availability
      end

      results = topic.evaluate_invariants([turn], conversation, judge)

      expect(results.has_pending?).to be true
      expect(results.pending.length).to eq(3)
    end
  end

  describe "#to_h" do
    it "returns hash representation" do
      topic = described_class.new(:greeting) do
        characteristic "Initial contact"
        agent_intent "Welcome user"
      end
      topic.successors = [:gathering]

      hash = topic.to_h
      expect(hash[:name]).to eq(:greeting)
      expect(hash[:characteristic]).to eq("Initial contact")
      expect(hash[:agent_intent]).to eq("Welcome user")
      expect(hash[:successors]).to eq([:gathering])
    end
  end
end
