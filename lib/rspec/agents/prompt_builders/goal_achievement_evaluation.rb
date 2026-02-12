module RSpec
  module Agents
    module PromptBuilders
      # Builds prompts for evaluating goal achievement in conversations
      class GoalAchievementEvaluation < Base
        class << self
          # Build a goal achievement evaluation prompt
          #
          # @param goal_description [String] The goal to evaluate against
          # @param conversation [Conversation] The conversation to evaluate
          # @return [String] The complete prompt
          def build(goal_description, conversation)
            <<~PROMPT
            You are evaluating whether a conversation between a user and an AI agent achieved a stated goal.

            ## Goal
            #{goal_description}

            ## Conversation
            #{format_conversation_with_details(conversation)}

            ## Instructions
            Determine if the goal was achieved based on the conversation above.

            Criteria for "achieved":
            - The user's goal was completed or satisfactorily addressed
            - The conversation reached a natural conclusion for the goal
            - Any required actions (tool calls, information delivery) occurred
            - The user would reasonably consider their objective met

            Criteria for "not achieved":
            - The goal remains incomplete
            - The conversation ended prematurely
            - Required information was not obtained or actions not taken
            - The user's objective was not met

            Respond with a JSON object:
            ```json
            {
              "achieved": true or false,
              "reasoning": "Clear explanation of why the goal was or was not achieved"
            }
            ```

            Be objective and fair. Focus on whether the stated goal was actually accomplished.
          PROMPT
          end

          # Parse the LLM response into a structured result
          #
          # @param response [LLM::Response] The LLM response
          # @return [Hash] { achieved: Boolean, reasoning: String }
          def parse(response)
            text = response.respond_to?(:text) ? response.text : response.to_s

            if response.respond_to?(:parsed) && response.parsed
              return {
                achieved:  !!response.parsed["achieved"],
                reasoning: response.parsed["reasoning"] || "No reasoning provided"
              }
            end

            parsed = safe_parse_json(text)
            if parsed
              {
                achieved:  !!parsed["achieved"],
                reasoning: parsed["reasoning"] || "No reasoning provided"
              }
            else
              # Fallback: analyze text for yes/no patterns
              achieved = text.downcase.include?("achieved") ||
                         text.downcase.include?('"achieved": true') ||
                         text.downcase.include?('"achieved":true')
              {
                achieved:  achieved,
                reasoning: text
              }
            end
          end

          private

          # Format conversation with turns, topics, and tool calls
          def format_conversation_with_details(conversation)
            turns = conversation.respond_to?(:turns) ? conversation.turns : []

            if turns.empty?
              return "No conversation turns available."
            end

            turns.map.with_index do |turn, i|
              format_turn(turn, i + 1)
            end.join("\n\n")
          end

          # Format a single turn with all details
          def format_turn(turn, index)
            parts = ["### Turn #{index}"]

            # Add topic if available
            if turn.respond_to?(:topic) && turn.topic
              parts << "Topic: #{turn.topic}"
            end

            # Add user message
            user_msg = turn.respond_to?(:user_message) ? turn.user_message : turn[:user_message]
            if user_msg
              user_text = user_msg.respond_to?(:text) ? user_msg.text : user_msg.to_s
              parts << "User: #{user_text}"
            end

            # Add agent response
            agent_resp = turn.respond_to?(:agent_response) ? turn.agent_response : turn[:agent_response]
            if agent_resp
              agent_text = agent_resp.respond_to?(:text) ? agent_resp.text : agent_resp.to_s
              parts << "Agent: #{agent_text}"
            end

            # Add tool calls if any
            tool_calls = turn.respond_to?(:tool_calls) ? turn.tool_calls : []
            if tool_calls.any?
              parts << format_turn_tool_calls(tool_calls)
            end

            parts.join("\n")
          end

          # Format tool calls for a turn
          def format_turn_tool_calls(tool_calls)
            tool_summaries = tool_calls.map do |tc|
              name = tc.respond_to?(:name) ? tc.name : tc[:name]
              args = tc.respond_to?(:arguments) ? tc.arguments : tc[:arguments]
              "#{name}(#{args.to_json})"
            end.join(", ")

            "Tool calls: #{tool_summaries}"
          end
        end
      end
    end
  end
end
