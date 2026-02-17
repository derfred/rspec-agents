# frozen_string_literal: true

# End-to-end test fixture for rspec-agents.
# This file has a .rb (not _spec.rb) ending so it is NOT picked up
# by rspec-agents' own spec discovery.  The integration test copies
# it into a temporary directory and renames it to _spec.rb before
# executing it via the CLI binary.

require "rspec/agents"

# ---------------------------------------------------------------------------
# Mock agent: echoes canned responses and optionally returns tool calls.
# Defined inline so the fixture is fully self-contained.
# ---------------------------------------------------------------------------
unless defined?(E2EMockAgent)
  class E2EMockAgent < RSpec::Agents::Agents::Base
    RESPONSES = []

    def self.enqueue(*entries)
      RESPONSES.clear
      entries.each { |e| RESPONSES << e }
    end

    def chat(messages, on_tool_call: nil)
      entry = RESPONSES.shift || "mock fallback response"
      tool_calls = []

      # Support [text, [tool_call_hashes]] tuples for tool calls
      if entry.is_a?(Array)
        text, tc_defs = entry
        tool_calls = (tc_defs || []).map do |tc|
          t = RSpec::Agents::ToolCall.new(**tc)
          on_tool_call&.call(t)
          t
        end
      else
        text = entry
      end

      RSpec::Agents::AgentResponse.new(text: text, tool_calls: tool_calls)
    end
  end
end

RSpec::Agents.configure { |c| c.agent = E2EMockAgent }

# ---------------------------------------------------------------------------
# Test suite exercising scripted conversation, criteria, and evaluations.
# ---------------------------------------------------------------------------
RSpec.describe "E2E fixture: booking agent", type: :agent do
  criterion :helpful, "The agent should be helpful"

  describe "Scripted greeting and booking" do
    it "handles a multi-turn booking conversation" do
      E2EMockAgent.enqueue(
        "Hello! How can I assist you today?",
        ["I found some great venues for you.",
          [{ name: :search_venues, arguments: { query: "venues for 50" }, result: { venues: ["Grand Hall"] } }]],
        "The Grand Hall costs 500 EUR per day.",
        "Booking confirmed! Your reference number is #42."
      )

      user.says "Hi, I need help planning an event"
      expect(agent.last_response).to include("Hello")

      user.says "I need a venue for 50 people"
      expect(agent.tool_calls).not_to be_empty

      user.says "What does it cost?"
      expect(agent.last_response).to include("500 EUR")

      user.says "Please book it"
      expect(agent.last_response).to include("Booking confirmed")
    end
  end

  describe "Evaluation recording" do
    it "records soft and hard evaluations" do
      E2EMockAgent.enqueue("Sure, I can help you with that!")

      user.says "Help me"

      # Hard assertion
      expect(agent).to satisfy(->(turn) { turn.agent_response.text.length < 500 })

      # Soft assertion
      evaluate(agent).to satisfy(->(turn) { turn.agent_response.text.include?("help") })
    end
  end
end
