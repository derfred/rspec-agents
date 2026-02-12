module RSpec
  module Agents
    # Represents a single turn in a conversation (user message + agent response)
    class Turn
      attr_reader :user_message, :agent_response
      attr_accessor :topic

      # @param user_message [String] The user's message text
      # @param agent_response [AgentResponse] The agent's response
      # @param topic [Symbol, nil] The topic this turn belongs to
      def initialize(user_message, agent_response, topic: nil)
        @user_message = user_message
        @agent_response = agent_response
        @topic = topic
      end

      # Get the agent's response text
      # @return [String, nil]
      def agent_text
        @agent_response&.text
      end

      # Get all tool calls from this turn
      # @return [Array<ToolCall>]
      def tool_calls
        @agent_response&.tool_calls || []
      end

      # Check if agent called a specific tool
      # @param tool_name [Symbol, String] Tool name to check
      # @return [Boolean]
      def has_tool_call?(tool_name)
        tool_calls.any? { |tc| tc.name == tool_name.to_sym }
      end

      # Find tool calls by name
      # @param tool_name [Symbol, String] Tool name to find
      # @return [Array<ToolCall>]
      def find_tool_calls(tool_name)
        tool_calls.select { |tc| tc.name == tool_name.to_sym }
      end

      # Get the first tool call by name
      # @param tool_name [Symbol, String] Tool name to find
      # @return [ToolCall, nil]
      def tool_call(tool_name)
        tool_calls.find { |tc| tc.name == tool_name.to_sym }
      end

      def to_h
        {
          user_message:   @user_message,
          agent_response: @agent_response&.to_h,
          topic:          @topic
        }
      end

      def inspect
        "#<#{self.class.name} topic=#{@topic.inspect} user=#{@user_message&.length || 0} chars>"
      end
    end
  end
end
