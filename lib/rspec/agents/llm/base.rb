module RSpec
  module Agents
    module Llm
      # Base class for LLM adapters used by judge and simulator
      # Provides a simple completion interface for structured output
      #
      # @example Implementing a custom LLM adapter
      #   class MyLLM < RSpec::Agents::Llm::Base
      #     def complete(prompt, response_format: :text, max_tokens: 1024)
      #       result = my_api.generate(prompt: prompt)
      #       Response.new(
      #         text: result.text,
      #         parsed: response_format == :json ? JSON.parse(result.text) : nil,
      #         metadata: { model: result.model }
      #       )
      #     end
      #   end
      class Base
        # Generate a completion from the LLM
        #
        # @param prompt [String] The complete prompt text
        # @param response_format [Symbol] :text or :json
        # @param max_tokens [Integer] Maximum tokens in response
        # @return [Response] The LLM response
        def complete(prompt, response_format: :text, max_tokens: 1024)
          raise NotImplementedError, "#{self.class} must implement #complete"
        end

        # Generate a completion with JSON schema validation
        # Default implementation embeds schema in prompt; override for native support
        #
        # @param prompt [String] The prompt text
        # @param schema [Hash] JSON schema for response validation
        # @param max_tokens [Integer] Maximum tokens in response
        # @return [Response] The LLM response with parsed JSON
        def complete_with_schema(prompt, schema:, max_tokens: 1024)
          augmented_prompt = <<~PROMPT
          #{prompt}

          Respond with JSON matching this schema:
          #{JSON.pretty_generate(schema)}

          Respond ONLY with the JSON object, no additional text.
        PROMPT
          complete(augmented_prompt, response_format: :json, max_tokens: max_tokens)
        end

        # Check if the LLM is available and configured
        #
        # @return [Boolean]
        def available?
          raise NotImplementedError, "#{self.class} must implement #available?"
        end

        # Get model identification for logging/debugging
        #
        # @return [String]
        def model_info
          "Unknown LLM"
        end
      end
    end
  end
end
