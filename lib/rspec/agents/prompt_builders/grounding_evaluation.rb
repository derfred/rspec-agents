module RSpec
  module Agents
    module PromptBuilders
      # Builds prompts for evaluating whether agent claims are grounded in tool results
      class GroundingEvaluation < Base
        class << self
          # Build a grounding evaluation prompt
          #
          # @param claim_types [Array<Symbol>] Types of claims to check (e.g., :venues, :pricing)
          # @param agent_text [String] The agent's response text
          # @param tool_calls [Array<ToolCall>] Tool calls with results
          # @param mode [Symbol] :expect_grounded or :forbid_claims
          # @return [String] The complete prompt
          def build(claim_types, agent_text, tool_calls, mode: :expect_grounded)
            case mode
            when :expect_grounded
              build_grounding_check(claim_types, agent_text, tool_calls)
            when :forbid_claims
              build_forbidden_claims_check(claim_types, agent_text, tool_calls)
            else
              raise ArgumentError, "Unknown mode: #{mode}"
            end
          end

          # Parse the LLM response into a grounding result
          #
          # @param response [LLM::Response] The LLM response
          # @param mode [Symbol] :expect_grounded or :forbid_claims
          # @return [Hash] Result with :grounded/:violated and :violations/:claims_found
          def parse(response, mode: :expect_grounded)
            text = response.respond_to?(:text) ? response.text : response.to_s

            parsed = if response.respond_to?(:parsed) && response.parsed
                       response.parsed
                     else
                       safe_parse_json(text)
                     end

            case mode
            when :expect_grounded
              parse_grounding_result(parsed, text)
            when :forbid_claims
              parse_forbidden_claims_result(parsed, text)
            else
              { grounded: true, violations: [] }
            end
          end

          private

          def build_grounding_check(claim_types, agent_text, tool_calls)
            <<~PROMPT
            You are a fact-checking expert. Your task is to verify that claims in an agent's response are properly grounded in tool call results.

            ## Claim Types to Verify
            The agent's response should contain claims about: #{claim_types.map(&:to_s).join(", ")}

            These claims MUST be supported by the tool call results below.

            ## Tool Call Results
            #{format_tool_calls(tool_calls)}

            ## Agent's Response
            #{agent_text}

            ## Instructions
            1. Identify any claims the agent makes about #{claim_types.map(&:to_s).join(", ")}
            2. For each claim, verify it is supported by the tool call results
            3. A claim is "grounded" if:
               - The information comes directly from tool results
               - Reasonable inferences from tool results are acceptable
               - Paraphrasing is acceptable if meaning is preserved

            Respond with a JSON object:
            ```json
            {
              "grounded": true or false,
              "claims_found": [
                {
                  "type": "claim_type",
                  "claim": "what the agent claimed",
                  "grounded": true or false,
                  "source": "which tool result supports this (or 'none')"
                }
              ],
              "violations": ["list of ungrounded claims"]
            }
            ```
          PROMPT
          end

          def build_forbidden_claims_check(claim_types, agent_text, tool_calls)
            <<~PROMPT
            You are a fact-checking expert. Your task is to verify that an agent's response does NOT make unsupported claims about certain topics.

            ## Forbidden Claim Types
            The agent should NOT make claims about: #{claim_types.map(&:to_s).join(", ")}

            UNLESS those claims are grounded in the tool call results below.

            ## Tool Call Results (if any)
            #{tool_calls.any? ? format_tool_calls(tool_calls) : "No tool calls were made."}

            ## Agent's Response
            #{agent_text}

            ## Instructions
            1. Scan the response for any claims about #{claim_types.map(&:to_s).join(", ")}
            2. If claims are found, check if they are grounded in tool results
            3. Flag any claims that are:
               - Made about forbidden topics AND
               - Not supported by tool call results

            Respond with a JSON object:
            ```json
            {
              "violated": true or false,
              "claims_found": [
                {
                  "type": "claim_type",
                  "claim": "what the agent claimed",
                  "grounded": true or false
                }
              ],
              "reasoning": "Brief explanation"
            }
            ```
          PROMPT
          end

          def parse_grounding_result(parsed, text)
            if parsed
              {
                grounded:     parsed["grounded"] != false,
                claims_found: parsed["claims_found"] || [],
                violations:   parsed["violations"] || []
              }
            else
              # Fallback
              grounded = text.downcase.include?('"grounded": true') ||
                         text.downcase.include?('"grounded":true')
              {
                grounded:     grounded,
                claims_found: [],
                violations:   grounded ? [] : ["Unable to parse grounding result"]
              }
            end
          end

          def parse_forbidden_claims_result(parsed, text)
            if parsed
              {
                violated:     !!parsed["violated"],
                claims_found: parsed["claims_found"] || [],
                reasoning:    parsed["reasoning"] || ""
              }
            else
              # Fallback
              violated = text.downcase.include?('"violated": true') ||
                         text.downcase.include?('"violated":true')
              {
                violated:     violated,
                claims_found: [],
                reasoning:    "Unable to parse forbidden claims result"
              }
            end
          end
        end
      end
    end
  end
end
