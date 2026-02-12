require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::Triggers do
  # Mock turn and conversation for testing
  let(:turn) do
    double("Turn",
      agent_response: RSpec::Agents::AgentResponse.new(
        text:       "I found some venues for you",
        tool_calls: [RSpec::Agents::ToolCall.new(name: :search_venues, arguments: { location: "Stuttgart" })]
      ),
      user_message:   "I need a venue in Stuttgart"
    )
  end

  let(:conversation) do
    double("Conversation", turns_in_topic: 0)
  end

  describe "#initialize" do
    it "creates empty triggers without block" do
      triggers = described_class.new
      expect(triggers.empty?).to be true
    end

    it "evaluates block to add triggers" do
      triggers = described_class.new do
        on_tool_call :search_venues
      end
      expect(triggers.count).to eq(1)
    end
  end

  describe "#on_tool_call" do
    it "matches when tool is called" do
      triggers = described_class.new do
        on_tool_call :search_venues
      end
      expect(triggers.any_match?(turn, conversation)).to be true
    end

    it "does not match when different tool called" do
      triggers = described_class.new do
        on_tool_call :book_venue
      end
      expect(triggers.any_match?(turn, conversation)).to be false
    end

    it "matches with param constraints" do
      triggers = described_class.new do
        on_tool_call :search_venues, with_params: { location: /stuttgart/i }
      end
      expect(triggers.any_match?(turn, conversation)).to be true
    end

    it "does not match when params don't match" do
      triggers = described_class.new do
        on_tool_call :search_venues, with_params: { location: /berlin/i }
      end
      expect(triggers.any_match?(turn, conversation)).to be false
    end
  end

  describe "#on_response_match" do
    it "matches when pattern found in response" do
      triggers = described_class.new do
        on_response_match /found.*venues/i
      end
      expect(triggers.any_match?(turn, conversation)).to be true
    end

    it "does not match when pattern not found" do
      triggers = described_class.new do
        on_response_match /error|sorry/i
      end
      expect(triggers.any_match?(turn, conversation)).to be false
    end
  end

  describe "#on_user_match" do
    it "matches when pattern found in user message" do
      triggers = described_class.new do
        on_user_match /venue.*stuttgart/i
      end
      expect(triggers.any_match?(turn, conversation)).to be true
    end

    it "does not match when pattern not found" do
      triggers = described_class.new do
        on_user_match /hotel/i
      end
      expect(triggers.any_match?(turn, conversation)).to be false
    end
  end

  describe "#after_turns_in" do
    it "matches when enough turns in topic" do
      conv = double("Conversation", turns_in_topic: 3)
      triggers = described_class.new do
        after_turns_in :gathering_details, count: 3
      end
      expect(triggers.any_match?(turn, conv)).to be true
    end

    it "does not match when not enough turns" do
      conv = double("Conversation", turns_in_topic: 2)
      triggers = described_class.new do
        after_turns_in :gathering_details, count: 3
      end
      expect(triggers.any_match?(turn, conv)).to be false
    end
  end

  describe "#on_condition" do
    it "matches when lambda returns true" do
      triggers = described_class.new do
        on_condition ->(t, c) { t.agent_response.text.length > 10 }
      end
      expect(triggers.any_match?(turn, conversation)).to be true
    end

    it "does not match when lambda returns false" do
      triggers = described_class.new do
        on_condition ->(t, c) { t.agent_response.text.length < 5 }
      end
      expect(triggers.any_match?(turn, conversation)).to be false
    end

    it "receives turn and conversation" do
      received_args = []
      triggers = described_class.new do
        on_condition ->(t, c) {
          received_args = [t, c]
          true
        }
      end
      triggers.any_match?(turn, conversation)
      expect(received_args).to eq([turn, conversation])
    end
  end

  describe "#any_match?" do
    it "returns true if any trigger matches" do
      triggers = described_class.new do
        on_tool_call :missing_tool
        on_response_match /found/
      end
      expect(triggers.any_match?(turn, conversation)).to be true
    end

    it "returns false if no triggers match" do
      triggers = described_class.new do
        on_tool_call :missing_tool
        on_response_match /error/
      end
      expect(triggers.any_match?(turn, conversation)).to be false
    end

    it "returns false for empty triggers" do
      triggers = described_class.new
      expect(triggers.any_match?(turn, conversation)).to be false
    end
  end

  describe "edge cases" do
    it "handles turn without agent_response" do
      empty_turn = double("Turn", agent_response: nil, user_message: "Hi")
      triggers = described_class.new do
        on_tool_call :search
        on_response_match /test/
      end
      expect(triggers.any_match?(empty_turn, conversation)).to be false
    end

    it "handles turn without user_message method" do
      turn_without_user = double("Turn",
        agent_response: RSpec::Agents::AgentResponse.new(text: "Hello")
      )
      allow(turn_without_user).to receive(:respond_to?).with(:agent_response).and_return(true)
      allow(turn_without_user).to receive(:respond_to?).with(:user_message).and_return(false)

      triggers = described_class.new do
        on_user_match /test/
      end
      expect(triggers.any_match?(turn_without_user, conversation)).to be false
    end
  end
end
