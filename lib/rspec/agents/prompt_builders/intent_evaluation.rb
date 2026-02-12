module RSpec
  module Agents
    module PromptBuilders
      # Builds prompts for evaluating agent intent
      class IntentEvaluation < Base
        class << self
          # Build an intent evaluation prompt
          #
          # @param intent_description [String] Description of expected intent
          # @param turn [Turn] The turn to evaluate
          # @param context [Hash] Additional context
          # @return [String] The complete prompt
          def build(intent_description, turn, context = {})
            <<~PROMPT
            You are an expert at analyzing conversational AI behavior. Your task is to evaluate whether an agent's response demonstrates a specific intent.

            ## Expected Intent
            #{intent_description}

            ## Turn to Evaluate
            #{format_turn(turn)}

            #{context_section(context)}

            ## Instructions
            Analyze whether the agent's response demonstrates the expected intent.

            Consider:
            - What is the agent trying to accomplish?
            - Does the response align with the stated intent?
            - Actions speak louder than words: consider tool calls and actual behavior

            Respond with a JSON object:
            ```json
            {
              "matches": true or false,
              "observed_intent": "Brief description of what intent the agent actually demonstrates",
              "reasoning": "Explanation of your evaluation"
            }
            ```
          PROMPT
          end

          # Parse the LLM response into an intent evaluation result
          #
          # @param response [LLM::Response] The LLM response
          # @return [Hash] { matches: Boolean, observed_intent: String, reasoning: String }
          def parse(response)
            text = response.respond_to?(:text) ? response.text : response.to_s

            parsed = if response.respond_to?(:parsed) && response.parsed
                       response.parsed
                     else
                       safe_parse_json(text)
                     end

            if parsed
              {
                matches:         !!parsed["matches"],
                observed_intent: parsed["observed_intent"] || "",
                reasoning:       parsed["reasoning"] || "No reasoning provided"
              }
            else
              # Fallback
              matches = text.downcase.include?('"matches": true') ||
                        text.downcase.include?('"matches":true')
              {
                matches:         matches,
                observed_intent: "Unable to determine",
                reasoning:       text
              }
            end
          end

          private

          def format_turn(turn)
            parts = []

            user_msg = turn.respond_to?(:user_message) ? turn.user_message : turn[:user_message]
            parts << "User: #{user_msg}" if user_msg

            agent_resp = turn.respond_to?(:agent_response) ? turn.agent_response : turn[:agent_response]
            if agent_resp
              agent_text = agent_resp.respond_to?(:text) ? agent_resp.text : agent_resp
              parts << "Agent: #{agent_text}"

              tool_calls = agent_resp.respond_to?(:tool_calls) ? agent_resp.tool_calls : nil
              if tool_calls && !tool_calls.empty?
                parts << "\nTool Calls Made:"
                parts << format_tool_calls(tool_calls)
              end
            end

            parts.join("\n")
          end

          def context_section(context)
            return "" if context.empty?

            parts = ["\n## Additional Context"]
            context.each do |key, value|
              parts << "#{key}: #{value}"
            end
            parts.join("\n")
          end
        end
      end
    end
  end
end
