module RSpec
  module Agents
    # Represents a response from the agent under test
    class AgentResponse
      attr_reader :text, :tool_calls, :metadata

      # @param text [String] The agent's response text
      # @param tool_calls [Array<ToolCall>] Tool calls made during this response
      # @param metadata [Metadata] Optional provider-specific data
      def initialize(text:, tool_calls: [], metadata: Metadata.new)
        @text = text
        @tool_calls = tool_calls
        @metadata = metadata
      end

      def has_tool_call?(name, params: nil)
        @tool_calls.any? do |tc|
          tc.name == name.to_sym && tc.matches_params?(params)
        end
      end

      def find_tool_calls(name, params: nil)
        @tool_calls.select do |tc|
          tc.name == name.to_sym && tc.matches_params?(params)
        end
      end

      def tool_call(name)
        @tool_calls.find { |tc| tc.name == name.to_sym }
      end

      def empty?
        @text.nil? || @text.empty?
      end

      def length
        @text&.length || 0
      end

      def match?(pattern)
        pattern.match?(@text.to_s)
      end

      def include?(substring)
        @text.to_s.include?(substring)
      end

      def to_h
        {
          text:       @text,
          tool_calls: @tool_calls.map(&:to_h),
          metadata:   @metadata.to_h
        }
      end

      def to_s
        @text.to_s
      end
    end
  end
end
