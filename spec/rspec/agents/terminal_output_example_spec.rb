require "spec_helper"

# Example spec to validate TerminalRunner output with conversation events
# Run with: RAILS_ENV=development bin/rspec-agents spec/rspec/agents/terminal_output_example_spec.rb

RSpec.describe "Terminal Output Example", type: :agent do
  # Mock agent that echoes back with some variation
  class EchoAgent < RSpec::Agents::Agents::Base
    def self.build(context = {})
      new
    end

    def chat(messages, on_tool_call: nil)
      last_user_message = messages.reverse.find { |m| m[:role] == "user" }&.dig(:content) || ""

      response_text = case last_user_message.downcase
                      when /hello|hi|hey/
                        "Hello! How can I help you today?"
                      when /yes.*book|confirm|book it|please.*book/
                        "I've booked the Grand Hall for you. Confirmation number: #12345"
                      when /venue|event/
                        "I'd be happy to help you find a venue. Could you tell me more about your event?"
                      when /people|attendees|capacity/
                        "Great! I found some options for you. The Grand Hall can accommodate up to 100 people."
                      when /price|cost|budget/
                        "The Grand Hall costs 500 EUR per day. Would you like me to check availability?"
                      else
                        "I understand. Is there anything else you'd like to know?"
                      end

      tool_calls = []
      if last_user_message.downcase.include?("venue") || last_user_message.downcase.include?("people")
        tool_calls << RSpec::Agents::ToolCall.new(
          name:      :search_venues,
          arguments: { query: last_user_message },
          result:    { venues: ["Grand Hall", "Conference Center"] }
        )
      end

      RSpec::Agents::AgentResponse.new(
        text:       response_text,
        tool_calls: tool_calls
      )
    end
  end

  # Configure the agent for all tests
  agent EchoAgent

  # Define shared topics
  topic :greeting do
    characteristic "Initial contact and welcome"
    agent_intent "Welcome the user and understand their needs"
  end

  topic :gathering_details do
    characteristic "Collecting event requirements like capacity, date, budget"
    agent_intent "Gather sufficient information for venue search"
  end

  topic :presenting_results do
    characteristic "Showing venue options to the user"
    agent_intent "Present relevant venues based on requirements"
    triggers { on_tool_call :search_venues }
  end

  topic :booking do
    characteristic "Confirming and finalizing the booking"
    agent_intent "Complete the reservation process"
  end

  # Define criteria
  criterion :friendly, "The agent's response should be friendly and welcoming"
  criterion :helpful, "The agent should help achieve the user's goal"

  # Configure simulator defaults
  simulator do
    role "Event planner looking for a venue"
    max_turns 5
  end

  describe "Scripted Conversations" do
    it "handles a simple greeting exchange" do
      user.says "Hello!"
      expect(agent.last_response).to include("Hello")

      user.says "I need to book a venue for an event"
      expect(agent.last_response).to include("venue")
    end

    it "handles a multi-turn booking flow" do
      expect_conversation_to do
        use_topic :greeting, next: :gathering_details
        use_topic :gathering_details, next: :presenting_results
        use_topic :presenting_results, next: :booking
        use_topic :booking
      end

      user.says "Hi there!"
      expect(agent).to be_in_topic(:greeting)

      user.says "I need a venue for 50 people"
      expect(agent.tool_calls).not_to be_empty

      user.says "What's the price?"
      expect(agent.last_response).to include("500 EUR")

      user.says "Yes, book it please"
      expect(agent.last_response).to include("Confirmation")
    end
  end

  describe "Simulated Conversations" do
    it "runs a goal-driven venue search simulation" do
      expect_conversation_to do
        use_topic :greeting, next: :gathering_details
        use_topic :gathering_details, next: :presenting_results
        use_topic :presenting_results, next: [:gathering_details, :booking]
        use_topic :booking
      end

      user.simulate do
        goal "Find and book a venue for a corporate workshop with 30 attendees"
        max_turns 4
      end

      expect(conversation.turns.count).to be >= 2
    end
  end
end
