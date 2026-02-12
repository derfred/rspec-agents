module RSpec
  module Agents
    module PromptBuilders
      # Base class with shared utilities for prompt builders
      class Base
        class << self
          # Extract JSON from LLM response text
          # Handles markdown code blocks and raw JSON
          #
          # @param text [String] Response text
          # @return [String, nil] Extracted JSON string or nil
          def extract_json(text)
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

          # Parse JSON with fallback error handling
          #
          # @param text [String] JSON text
          # @return [Hash, nil] Parsed hash or nil on error
          def safe_parse_json(text)
            return nil if text.nil? || text.empty?

            json_text = extract_json(text)
            return nil unless json_text

            fixed_json = fix_json_newlines(json_text)
            JSON.parse(fixed_json)
          rescue JSON::ParserError
            nil
          end

          # Fix JSON strings that contain literal newlines
          # LLMs sometimes return JSON with unescaped newlines within string values
          #
          # @param json_str [String] JSON string to fix
          # @return [String] Fixed JSON string
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

          # Format messages array for display in prompts
          #
          # @param messages [Array<Message, Hash>] Messages with role and content
          # @return [String] Formatted conversation text
          def format_conversation(messages)
            messages.map do |msg|
              role = msg.respond_to?(:role) ? msg.role : (msg[:role] || msg["role"])
              content = msg.respond_to?(:content) ? msg.content : (msg[:content] || msg["content"])
              "#{role.to_s.capitalize}: #{content}"
            end.join("\n\n")
          end

          # Format tool calls for display in prompts
          #
          # @param tool_calls [Array<ToolCall, Hash>] Tool calls
          # @return [String] Formatted tool calls text
          def format_tool_calls(tool_calls)
            return "" if tool_calls.nil? || tool_calls.empty?

            tool_calls.map do |tc|
              name = tc.respond_to?(:name) ? tc.name : (tc[:name] || tc["name"])
              args = tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc["arguments"] || {})
              result = tc.respond_to?(:result) ? tc.result : (tc[:result] || tc["result"])

              output = "Tool: #{name}\nArguments: #{args.to_json}"
              output += "\nResult: #{result}" if result
              output
            end.join("\n\n")
          end
        end
      end
    end
  end
end
