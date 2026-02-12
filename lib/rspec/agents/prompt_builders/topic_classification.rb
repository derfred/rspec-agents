module RSpec
  module Agents
    module PromptBuilders
      # Builds prompts for classifying which topic a turn belongs to
      class TopicClassification < Base
        class << self
          # Build a topic classification prompt
          #
          # @param turn [Turn] The turn to classify
          # @param conversation [Conversation] Full conversation context
          # @param possible_topics [Array<Topic>] Topics that could apply
          # @return [String] The complete prompt
          def build(turn, conversation, possible_topics)
            <<~PROMPT
            You are a conversation analyst. Your task is to classify which topic/phase the current turn of a conversation belongs to.

            ## Possible Topics
            #{format_topics(possible_topics)}

            ## Conversation History
            #{format_conversation_history(conversation)}

            ## Current Turn to Classify
            User: #{turn.user_message}
            Agent: #{turn.agent_response&.text}

            ## Instructions
            Based on the agent's response and the conversation context, determine which topic best describes the current state of the conversation.

            Consider:
            - The characteristic description of each topic
            - The agent's stated intent for each topic
            - What the agent is currently doing or discussing

            Respond with a JSON object:
            ```json
            {
              "topic": "topic_name",
              "confidence": "high" or "medium" or "low",
              "reasoning": "Brief explanation of why this topic was chosen"
            }
            ```

            Choose exactly one topic from the list above.
          PROMPT
          end

          # Parse the LLM response into a topic classification
          #
          # @param response [LLM::Response] The LLM response
          # @param valid_topics [Array<Symbol>] Valid topic names
          # @return [Hash] { topic: Symbol, confidence: String, reasoning: String }
          def parse(response, valid_topics)
            text = response.respond_to?(:text) ? response.text : response.to_s

            parsed = if response.respond_to?(:parsed) && response.parsed
                       response.parsed
                     else
                       safe_parse_json(text)
                     end

            if parsed && parsed["topic"]
              topic = parsed["topic"].to_sym
              # Validate topic is in allowed list
              topic = valid_topics.first unless valid_topics.include?(topic)

              {
                topic:      topic,
                confidence: parsed["confidence"] || "medium",
                reasoning:  parsed["reasoning"] || "No reasoning provided"
              }
            else
              # Fallback: try to find topic name in text
              topic = valid_topics.find { |t| text.downcase.include?(t.to_s) } || valid_topics.first
              {
                topic:      topic,
                confidence: "low",
                reasoning:  "Fallback classification from text analysis"
              }
            end
          end

          private

          def format_topics(topics)
            topics.map do |topic|
              parts = ["### #{topic.name}"]
              parts << "Characteristic: #{topic.characteristic_text}" if topic.characteristic_text
              parts << "Agent Intent: #{topic.agent_intent_text}" if topic.agent_intent_text
              parts.join("\n")
            end.join("\n\n")
          end

          def format_conversation_history(conversation)
            return "No previous messages." if conversation.messages.empty?

            conversation.messages.last(6).map do |msg|
              "#{msg.role.to_s.capitalize}: #{msg.content}"
            end.join("\n\n")
          end
        end
      end
    end
  end
end
