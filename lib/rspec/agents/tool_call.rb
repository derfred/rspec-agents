module RSpec
  module Agents
    # Represents a tool invocation by the agent
    class ToolCall
      attr_reader :name, :arguments, :result, :metadata

      def initialize(name:, arguments: {}, result: nil, metadata: {})
        @name = name.to_sym
        @arguments = arguments
        @result = result
        @metadata = metadata.is_a?(Metadata) ? metadata : Metadata.new(metadata)
      end

      def has_argument?(key)
        @arguments.key?(key.to_sym) || @arguments.key?(key.to_s)
      end

      def argument(key)
        @arguments[key.to_sym] || @arguments[key.to_s]
      end

      def matches_params?(expected_params)
        return true if expected_params.nil? || expected_params.empty?

        expected_params.all? do |key, expected_value|
          actual_value = argument(key)
          case expected_value
          when Regexp
            expected_value.match?(actual_value.to_s)
          when Proc
            expected_value.call(actual_value)
          else
            actual_value == expected_value
          end
        end
      end

      def to_h
        {
          name:      @name,
          arguments: @arguments,
          result:    @result,
          metadata:  @metadata.to_h
        }
      end

      def ==(other)
        return false unless other.is_a?(ToolCall)
        name == other.name && arguments == other.arguments
      end
    end
  end
end
