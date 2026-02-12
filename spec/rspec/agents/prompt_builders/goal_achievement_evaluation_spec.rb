require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::PromptBuilders::GoalAchievementEvaluation do
  describe ".build" do
    let(:goal_description) { "Find a venue for 50 people under 30,000 EUR" }

    let(:mock_conversation) do
      # Create mock conversation with turns
      conv = double("Conversation")

      user_msg1 = double("Message", text: "I need a venue for 50 people")
      agent_resp1 = double("Response", text: "I can help you find a venue. What's your budget?")
      turn1 = double("Turn",
        user_message:   user_msg1,
        agent_response: agent_resp1,
        topic:          :greeting,
        tool_calls:     []
      )

      user_msg2 = double("Message", text: "Our budget is 30,000 EUR")
      agent_resp2 = double("Response", text: "Great, let me search for venues")
      tool_call = double("ToolCall",
        name:      :search_venues,
        arguments: { capacity: 50, max_budget: 30000 }
      )
      turn2 = double("Turn",
        user_message:   user_msg2,
        agent_response: agent_resp2,
        topic:          :gathering_details,
        tool_calls:     [tool_call]
      )

      allow(conv).to receive(:turns).and_return([turn1, turn2])
      conv
    end

    it "builds a prompt with goal and conversation" do
      prompt = described_class.build(goal_description, mock_conversation)

      expect(prompt).to include("Find a venue for 50 people under 30,000 EUR")
      expect(prompt).to include("Turn 1")
      expect(prompt).to include("Turn 2")
      expect(prompt).to include("I need a venue for 50 people")
      expect(prompt).to include("Our budget is 30,000 EUR")
    end

    it "includes topic information" do
      prompt = described_class.build(goal_description, mock_conversation)

      expect(prompt).to include("Topic: greeting")
      expect(prompt).to include("Topic: gathering_details")
    end

    it "includes tool calls" do
      prompt = described_class.build(goal_description, mock_conversation)

      expect(prompt).to include("Tool calls:")
      expect(prompt).to include("search_venues")
    end

    it "includes criteria for evaluation" do
      prompt = described_class.build(goal_description, mock_conversation)

      expect(prompt).to include('Criteria for "achieved"')
      expect(prompt).to include('Criteria for "not achieved"')
    end

    it "requests JSON response format" do
      prompt = described_class.build(goal_description, mock_conversation)

      expect(prompt).to include("```json")
      expect(prompt).to include('"achieved"')
      expect(prompt).to include('"reasoning"')
    end

    it "handles empty conversation" do
      empty_conv = double("Conversation", turns: [])

      prompt = described_class.build(goal_description, empty_conv)

      expect(prompt).to include("No conversation turns available")
    end
  end

  describe ".parse" do
    it "parses structured response with parsed field" do
      response = double("Response",
        text:   "some text",
        parsed: { "achieved" => true, "reasoning" => "Goal was met" }
      )

      result = described_class.parse(response)

      expect(result[:achieved]).to be true
      expect(result[:reasoning]).to eq("Goal was met")
    end

    it "parses JSON from text response" do
      response = double("Response",
        text:   '```json\n{"achieved": true, "reasoning": "All requirements satisfied"}\n```',
        parsed: nil
      )

      result = described_class.parse(response)

      expect(result[:achieved]).to be true
      expect(result[:reasoning]).to eq("All requirements satisfied")
    end

    it "parses JSON without markdown wrapper" do
      response = double("Response",
        text:   '{"achieved": false, "reasoning": "Incomplete"}',
        parsed: nil
      )

      result = described_class.parse(response)

      expect(result[:achieved]).to be false
      expect(result[:reasoning]).to eq("Incomplete")
    end

    it "handles response without reasoning" do
      response = double("Response",
        text:   '{"achieved": true}',
        parsed: nil
      )

      result = described_class.parse(response)

      expect(result[:achieved]).to be true
      expect(result[:reasoning]).to eq("No reasoning provided")
    end

    it "falls back to text analysis when JSON parsing fails" do
      response = double("Response",
        text:   "Yes, the goal was achieved. All requirements were met.",
        parsed: nil
      )

      result = described_class.parse(response)

      # Fallback looks for "achieved" keyword
      expect(result[:achieved]).to be true
      expect(result[:reasoning]).to include("achieved")
    end

    it "handles string response" do
      response = '{"achieved": true, "reasoning": "Goal met"}'

      result = described_class.parse(response)

      expect(result[:achieved]).to be true
      expect(result[:reasoning]).to eq("Goal met")
    end
  end
end
