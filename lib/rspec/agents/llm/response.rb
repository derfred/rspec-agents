module RSpec
  module Agents
    module Llm
      # Represents a response from an LLM completion
      class Response
        attr_reader :text, :parsed, :metadata

        # @param text [String] Raw response text
        # @param parsed [Hash, nil] Parsed JSON if response_format was :json
        # @param metadata [Hash] Additional metadata (model, tokens, latency, etc.)
        def initialize(text:, parsed: nil, metadata: {})
          @text = text
          @parsed = parsed
          @metadata = metadata.is_a?(Metadata) ? metadata : Metadata.new(metadata)
        end

        # Check if JSON parsing succeeded
        #
        # @return [Boolean]
        def parsed?
          !@parsed.nil?
        end

        # Check if there was a parse error
        #
        # @return [Boolean]
        def parse_error?
          @metadata[:parse_error].present?
        end

        # Get the parse error message if any
        #
        # @return [String, nil]
        def parse_error
          @metadata[:parse_error]
        end

        def to_h
          {
            text:     @text,
            parsed:   @parsed,
            metadata: @metadata.to_h
          }
        end

        def inspect
          "#<#{self.class.name} text=#{@text&.length || 0} chars, parsed=#{parsed?}>"
        end
      end
    end
  end
end
