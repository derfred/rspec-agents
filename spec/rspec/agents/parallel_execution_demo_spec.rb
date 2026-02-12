# frozen_string_literal: true

require "spec_helper"
require "rspec/agents"

# Demo specs that simulate LLM-based agent tests with realistic timing
# Uses the Conversation class to emit real events that stream to the terminal
#
# Run with: bin/rspec-parallel -w 4 spec/rspec_agents/parallel_execution_demo_spec.rb

RSpec.describe "Parallel Execution Demo" do
  # Get the event bus (either isolated from worker or singleton)
  def event_bus
    Thread.current[:rspec_agents_event_bus] || RSpec::Agents::EventBus.instance
  end

  # Create a conversation that emits events
  def create_conversation
    RSpec::Agents::Conversation.new(event_bus: event_bus)
  end

  # Simulate an LLM response with delay
  def simulate_agent_response(text, delay: 0.3, tool_calls: [])
    sleep(delay)
    RSpec::Agents::AgentResponse.new(
      text:       text,
      tool_calls: tool_calls,
      metadata:   RSpec::Agents::Metadata.new
    )
  end

  # Run a simulated conversation turn
  def conversation_turn(conversation, user_message:, agent_response:, delay: 0.3)
    conversation.add_user_message(user_message, source: :simulator)
    response = simulate_agent_response(agent_response, delay: delay)
    conversation.add_agent_response(response)
    response
  end

  describe "BookingAgent" do
    describe "greeting flow" do
      it "welcomes the user warmly" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Hi, I need to book a venue",
          agent_response: "Hello! I'd be happy to help you book a venue. What type of event are you planning?",
          delay:          0.4
        )


        expect(conversation.turn_count).to eq(1)
      end

      it "asks for booking details" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "I'm planning a corporate retreat",
          agent_response: "Great! A corporate retreat sounds exciting. How many attendees are you expecting?",
          delay:          0.3
        )

        conversation_turn(
          conversation,
          user_message:   "About 50 people",
          agent_response: "Perfect, 50 attendees. What dates are you considering for this retreat?",
          delay:          0.3
        )


        expect(conversation.turn_count).to eq(2)
      end

      it "confirms user preferences" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "We need AV equipment and catering",
          agent_response: "Noted! I'll filter for venues with AV equipment and catering services included.",
          delay:          0.3
        )


        expect(conversation.messages.last.content).to include("AV equipment")
      end
    end

    describe "venue search" do
      it "searches for venues by location" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Find venues in Berlin",
          agent_response: "I found 12 venues in Berlin that match your criteria. Would you like me to show the top options?",
          delay:          0.5
        )


        expect(conversation.last_agent_response.text).to include("Berlin")
      end

      it "filters by capacity" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Need space for 50 people",
          agent_response: "I've filtered to show venues that can accommodate 50+ guests. Here are your options...",
          delay:          0.4
        )


        expect(conversation.turn_count).to eq(1)
      end

      it "handles complex multi-criteria search" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Looking for a conference room in Munich",
          agent_response: "Searching for conference rooms in Munich...",
          delay:          0.25
        )

        conversation_turn(
          conversation,
          user_message:   "With catering options please",
          agent_response: "Adding catering filter. Found 8 venues with in-house catering.",
          delay:          0.25
        )

        conversation_turn(
          conversation,
          user_message:   "Budget under 500 euros",
          agent_response: "Filtered to venues under €500. Here are 5 matching options...",
          delay:          0.25
        )


        expect(conversation.turn_count).to eq(3)
      end
    end

    describe "booking confirmation" do
      it "summarizes and confirms the booking" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Book the Grand Hotel conference room",
          agent_response: "Booking confirmed! Grand Hotel Conference Room for March 15th, 50 guests. Confirmation #BK2024-1234",
          delay:          0.4
        )

        conversation_turn(
          conversation,
          user_message:   "Send me the confirmation",
          agent_response: "I've sent the confirmation details to your email. Is there anything else you need?",
          delay:          0.3
        )


        expect(conversation.turn_count).to eq(2)
      end
    end
  end

  describe "SearchAgent" do
    describe "natural language queries" do
      it "understands location-based queries" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Hotels near Frankfurt airport",
          agent_response: "Found 15 hotels within 5km of Frankfurt Airport. Prices range from €89-€250/night.",
          delay:          0.4
        )


        expect(conversation.last_agent_response.text).to include("Frankfurt")
      end

      it "handles date range queries" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Check-in March 15, check-out March 20",
          agent_response: "Showing availability for 5 nights (March 15-20). 23 hotels have rooms available.",
          delay:          0.35
        )


        expect(conversation.turn_count).to eq(1)
      end

      it "processes budget constraints" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Max budget 200 per night",
          agent_response: "Filtered to hotels under €200/night. 18 options remain. Want me to sort by rating?",
          delay:          0.3
        )


        expect(conversation.last_agent_response.text).to include("200")
      end
    end

    describe "refinement flow" do
      it "narrows down results iteratively" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Show only 4-star hotels",
          agent_response: "Filtered to 4-star hotels. 7 properties match. Top rated: Hotel Excelsior (4.8★)",
          delay:          0.35
        )

        conversation_turn(
          conversation,
          user_message:   "With free breakfast",
          agent_response: "5 hotels offer complimentary breakfast. Shall I show details?",
          delay:          0.3
        )


        expect(conversation.turn_count).to eq(2)
      end
    end
  end

  describe "SupportAgent" do
    describe "FAQ handling" do
      it "answers billing questions" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "How do I update my payment method?",
          agent_response: "To update your payment method: Go to Settings → Payment → Add New Card. Need a walkthrough?",
          delay:          0.35
        )


        expect(conversation.last_agent_response.text).to include("payment")
      end

      it "explains cancellation policy" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "What is the cancellation policy?",
          agent_response: "Free cancellation up to 48 hours before check-in. After that, first night is charged.",
          delay:          0.3
        )


        expect(conversation.turn_count).to eq(1)
      end

      it "provides contact information" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "How can I reach customer support?",
          agent_response: "You can reach us at support@example.com or call +49-123-456-7890 (24/7).",
          delay:          0.25
        )


        expect(conversation.last_agent_response.text).to include("support")
      end
    end

    describe "escalation flow" do
      it "recognizes frustration and offers help" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "This is ridiculous, I need help NOW!",
          agent_response: "I understand your frustration and I'm here to help. Let me prioritize your issue right away.",
          delay:          0.4
        )

        conversation_turn(
          conversation,
          user_message:   "My booking disappeared!",
          agent_response: "I see booking #BK2024-5678 in your account. It shows as confirmed. Let me verify the details...",
          delay:          0.35
        )


        expect(conversation.turn_count).to eq(2)
      end
    end
  end

  describe "AnalyticsAgent" do
    describe "report generation" do
      it "generates daily summary" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Show me today's booking summary",
          agent_response: "Daily Summary: 47 new bookings, €23,450 revenue, 94% satisfaction. Top venue: Grand Hotel.",
          delay:          0.5
        )


        expect(conversation.turn_count).to eq(1)
      end

      it "creates weekly trends" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "What are this week's trends?",
          agent_response: "Weekly Trends: Bookings up 12%, Berlin leads with 34% of reservations, avg stay 2.3 nights.",
          delay:          0.45
        )


        expect(conversation.last_agent_response.text).to include("Trends")
      end

      it "produces monthly overview with details" do
        conversation = create_conversation

        conversation_turn(
          conversation,
          user_message:   "Generate monthly report",
          agent_response: "Generating comprehensive monthly report...",
          delay:          0.3
        )

        conversation_turn(
          conversation,
          user_message:   "Include revenue breakdown",
          agent_response: "Monthly Report: 1,234 bookings, €567,890 total revenue. Corporate: 45%, Leisure: 35%, Events: 20%",
          delay:          0.4
        )


        expect(conversation.turn_count).to eq(2)
      end
    end
  end
end
