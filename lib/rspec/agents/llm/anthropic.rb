module RSpec
  module Agents
    module Llm
      # Anthropic Claude LLM adapter
      # Requires the 'anthropic' gem to be installed
      class Anthropic < Base
        DEFAULT_MODEL = "claude-sonnet-4-20250514"

        # @param model [String] Model identifier
        # @param api_key [String, nil] API key (defaults to ANTHROPIC_API_KEY env var)
        def initialize(model: DEFAULT_MODEL, api_key: nil)
          @model = model
          @api_key = api_key
          @client = nil
          # Lazy load the anthropic gem
          require "anthropic" unless defined?(::Anthropic)
        end

        def complete(prompt, response_format: :text, max_tokens: 1024)
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          response = client.messages.create(
            model:      @model,
            messages:   [{ role: "user", content: prompt }],
            max_tokens: max_tokens
          )

          latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
          text = extract_text(response)
          parsed, parse_error = parse_if_json(text, response_format)

          Response.new(
            text:     text,
            parsed:   parsed,
            metadata: {
              model:         response.model,
              latency_ms:    latency_ms,
              input_tokens:  response.usage.input_tokens,
              output_tokens: response.usage.output_tokens,
              stop_reason:   response.stop_reason,
              parse_error:   parse_error
            }
          )
        end

        def available?
          effective_api_key.present?
        end

        def model_info
          "Anthropic #{@model}"
        end

        private

        def client
          @client ||= ::Anthropic::Client.new(api_key: effective_api_key)
        end

        def effective_api_key
          @api_key || ENV["ANTHROPIC_API_KEY"] || rails_api_key
        end

        def rails_api_key
          return nil unless defined?(Rails)
          Rails.application.config.try(:anthropic_api_key)
        end

        def extract_text(response)
          content_block = response.content.find do |c|
            type = c.respond_to?(:type) ? c.type : c[:type]
            type.to_s == "text"
          end
          return "" unless content_block
          content_block.respond_to?(:text) ? content_block.text : content_block[:text]
        end

        def parse_if_json(text, format)
          return [nil, nil] unless format == :json

          # Try to extract JSON from markdown code blocks first
          json_text = extract_json_from_response(text)
          return [nil, "No JSON found in response"] unless json_text

          # Fix common LLM JSON issues (unescaped newlines)
          fixed_json = fix_json_newlines(json_text)
          [JSON.parse(fixed_json), nil]
        rescue JSON::ParserError => e
          [nil, e.message]
        end

        def extract_json_from_response(text)
          # Try markdown code block first
          markdown_match = text.match(/```(?:json)?\s*(.+?)```/m)
          if markdown_match
            code_content = markdown_match[1]
            json_obj_match = code_content.match(/(\{.+\})/m)
            return json_obj_match[1] if json_obj_match
          end

          # Fallback: find JSON object directly
          json_match = text.match(/\{[\s\S]*\}/m)
          json_match ? json_match[0] : nil
        end

        # Fix JSON strings that contain literal newlines
        # LLMs sometimes return JSON with unescaped newlines within string values
        def fix_json_newlines(json_str)
          in_string = false
          escape_next = false
          result = []

          json_str.each_char do |char|
            if escape_next
              result << char
              escape_next = false
              next
            end

            case char
            when "\\"
              result << char
              escape_next = true
            when '"'
              result << char
              in_string = !in_string
            when "\n"
              result << (in_string ? "\\n" : char)
            when "\r"
              result << (in_string ? "\\r" : char)
            when "\t"
              result << (in_string ? "\\t" : char)
            else
              result << char
            end
          end

          result.join
        end
      end
    end
  end
end
