module RSpec
  module Agents
    module PromptBuilders
      # Builds prompts for evaluating quality criteria
      class CriterionEvaluation < Base
        class << self
          # Build a criterion evaluation prompt
          #
          # @param criterion [CriterionDefinition] The criterion to evaluate
          # @param turns [Array<Turn>] Turns to evaluate
          # @param context [Hash] Additional context (conversation history, etc.)
          # @return [String] The complete prompt
          def build(criterion, turns, context = {})
            <<~PROMPT
            You are an expert evaluator for conversational AI agents. Your task is to evaluate whether the agent's responses satisfy a specific quality criterion.

            ## Criterion
            Name: #{criterion.name}
            Description: #{criterion.description}

            #{examples_section(criterion)}

            ## Responses to Evaluate
            #{format_turns(turns)}

            #{context_section(context)}

            ## Instructions
            Evaluate whether ALL of the agent's responses above satisfy the criterion "#{criterion.name}".

            Respond with a JSON object:
            ```json
            {
              "satisfied": true or false,
              "reasoning": "Brief explanation of your evaluation"
            }
            ```

            Be strict but fair. Consider the criterion description and any examples provided.
          PROMPT
          end

          # Parse the LLM response into a structured result
          #
          # @param response [LLM::Response] The LLM response
          # @return [Hash] { satisfied: Boolean, reasoning: String }
          def parse(response)
            text = response.respond_to?(:text) ? response.text : response.to_s

            if response.respond_to?(:parsed) && response.parsed
              return {
                satisfied: !!response.parsed["satisfied"],
                reasoning: response.parsed["reasoning"] || "No reasoning provided"
              }
            end

            parsed = safe_parse_json(text)
            if parsed
              {
                satisfied: !!parsed["satisfied"],
                reasoning: parsed["reasoning"] || "No reasoning provided"
              }
            else
              # Fallback: analyze text for yes/no patterns
              satisfied = text.downcase.include?("satisfied") ||
                          text.downcase.include?('"satisfied": true') ||
                          text.downcase.include?('"satisfied":true')
              {
                satisfied: satisfied,
                reasoning: text
              }
            end
          end

          private

          def examples_section(criterion)
            return "" unless criterion.respond_to?(:has_examples?) && criterion.has_examples?

            parts = []

            if criterion.good_examples.any?
              parts << "### Good Examples (criterion satisfied)"
              criterion.good_examples.each do |ex|
                parts << "- \"#{ex[:text]}\""
                parts << "  Explanation: #{ex[:explanation]}"
              end
            end

            if criterion.bad_examples.any?
              parts << "\n### Bad Examples (criterion NOT satisfied)"
              criterion.bad_examples.each do |ex|
                parts << "- \"#{ex[:text]}\""
                parts << "  Explanation: #{ex[:explanation]}"
              end
            end

            if criterion.edge_cases.any?
              parts << "\n### Edge Cases"
              criterion.edge_cases.each do |ex|
                verdict = ex[:verdict] ? "SATISFIED" : "NOT SATISFIED"
                parts << "- \"#{ex[:text]}\" -> #{verdict}"
                parts << "  Explanation: #{ex[:explanation]}"
              end
            end

            "\n## Calibration Examples\n#{parts.join("\n")}"
          end

          def format_turns(turns)
            turns.map.with_index do |turn, i|
              user_msg = turn.respond_to?(:user_message) ? turn.user_message : turn[:user_message]
              agent_resp = turn.respond_to?(:agent_response) ? turn.agent_response : turn[:agent_response]
              agent_text = agent_resp.respond_to?(:text) ? agent_resp.text : agent_resp

              parts = ["### Turn #{i + 1}"]
              parts << "User: #{user_msg}" if user_msg
              parts << "Agent: #{agent_text}"
              parts.join("\n")
            end.join("\n\n")
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
