module RSpec
  module Agents
    # Represents a single message in a conversation
    # Messages capture the content of a user or agent turn along with associated metadata
    class Message
      attr_reader :role, :content, :timestamp, :tool_calls, :metadata

      # @param role [Symbol, String] :user or :agent
      # @param content [String] The message text
      # @param timestamp [Time] When the message was sent/received (defaults to now)
      # @param tool_calls [Array<ToolCall>] Tool calls made during this message (agent messages only)
      # @param metadata [Hash, Metadata] Optional provider-specific data
      def initialize(role:, content:, timestamp: nil, tool_calls: nil, metadata: nil)
        @role = role.to_sym
        @content = content
        @timestamp = timestamp || Time.now
        @tool_calls = tool_calls || []
        @metadata = normalize_metadata(metadata)
      end

      # @return [Boolean] true if this is a user message
      def user?
        @role == :user
      end

      # @return [Boolean] true if this is an agent message
      def agent?
        @role == :agent
      end

      # Check if this message contains a specific tool call
      #
      # @param name [Symbol, String] Tool name
      # @return [Boolean]
      def has_tool_call?(name)
        @tool_calls.any? { |tc| tc.name == name.to_sym }
      end

      # Hash-style access for convenience
      # Allows code like `msg[:content]` or `msg["role"]` to work
      #
      # @param key [Symbol, String] The attribute to access
      # @return [Object, nil] The attribute value
      def [](key)
        case key.to_sym
        when :role then @role
        when :content then @content
        when :timestamp then @timestamp
        when :tool_calls then @tool_calls
        when :metadata then @metadata
        end
      end

      # Serialize to hash
      #
      # @return [Hash]
      def to_h
        {
          role:       @role,
          content:    @content,
          timestamp:  @timestamp,
          tool_calls: @tool_calls.map { |tc| tc.respond_to?(:to_h) ? tc.to_h : tc },
          metadata:   @metadata.respond_to?(:to_h) ? @metadata.to_h : @metadata
        }
      end

      def inspect
        tool_info = @tool_calls.any? ? " tool_calls=#{@tool_calls.count}" : ""
        "#<#{self.class.name} role=#{@role}#{tool_info} content=#{@content.to_s[0..50].inspect}>"
      end

      private

      def normalize_metadata(metadata)
        return Metadata.new({}) if metadata.nil?
        return metadata if metadata.is_a?(Metadata)
        Metadata.new(metadata)
      end
    end
  end
end
