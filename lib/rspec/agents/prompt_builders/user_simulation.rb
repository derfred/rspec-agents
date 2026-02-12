require "erb"

module RSpec
  module Agents
    module PromptBuilders
      # Builds prompts for simulating user messages
      class UserSimulation < Base
        DEFAULT_TEMPLATE_PATH = File.expand_path("../templates/user_simulation.erb", __dir__)

        class << self
          # Build a user simulation prompt
          #
          # @param config [SimulatorConfig] Simulator configuration
          # @param conversation [Conversation] Current conversation state
          # @param current_topic [Topic, nil] Current topic (for topic-specific overrides)
          # @return [String] The complete prompt
          def build(config, conversation, current_topic: nil)
            effective_config = current_topic ? config.for_topic(current_topic.name) : config
            template_path = effective_config.template || DEFAULT_TEMPLATE_PATH

            render_template(template_path, effective_config, conversation)
          end

          # Parse the response (typically just the raw text)
          #
          # @param response [LLM::Response] The LLM response
          # @return [String] The user message
          def parse(response)
            text = response.respond_to?(:text) ? response.text : response.to_s
            # Clean up any quotes or prefixes the LLM might add
            text.strip
                .gsub(/^["']|["']$/, "")
                .gsub(/^User:\s*/i, "")
                .strip
          end

          private

          def render_template(template_path, config, conversation)
            template_content = File.read(template_path)
            erb = ERB.new(template_content, trim_mode: "-")

            # Variables available in the template
            system_section = build_system_section(config)
            conversation_section = build_conversation_section(conversation)
            rules_section = build_rules_section(config, conversation)
            turn_count = conversation.turns.count

            erb.result(binding)
          end

          def build_system_section(config)
            parts = ["## Your Role"]
            parts << "You are pretending to be a user testing an AI agent."
            parts << "Approach this naturally, as a human user would."
            parts << ""

            role_items = config.effective_role
            if role_items.any?
              parts << "### Character"
              parts.concat(role_items)
              parts << ""
            end

            personality_items = config.effective_personality
            if personality_items.any?
              parts << "### Personality"
              parts.concat(personality_items)
              parts << ""
            end

            context_items = config.effective_context
            if context_items.any?
              parts << "### Context"
              parts.concat(context_items)
              parts << ""
            end

            if config.goal
              parts << "### Goal"
              parts << "Your goal is: #{config.goal}"
              parts << ""
            end

            parts.join("\n")
          end

          def build_conversation_section(conversation)
            if conversation.messages.empty?
              return "## Conversation So Far\nThis is the start of the conversation. Send your opening message."
            end

            parts = ["## Conversation So Far"]
            conversation.messages.each do |msg|
              # Flip roles: in conversation, "agent" is who user is talking to
              display_role = msg.role == :agent ? "Agent" : "You"
              parts << "#{display_role}: #{msg.content}"
            end

            parts.join("\n")
          end

          def build_rules_section(config, conversation)
            rules = config.rules || []
            return "" if rules.empty?

            parts = ["## Rules to Follow"]

            rules.each do |rule|
              case rule[:type]
              when :should
                parts << "- You SHOULD: #{rule[:text]}"
              when :should_not
                parts << "- You should NOT: #{rule[:text]}"
              when :dynamic
                # Evaluate dynamic rule
                if rule[:block]
                  last_turn = conversation.turns.last
                  dynamic_text = rule[:block].call(last_turn&.agent_response, conversation)
                  parts << "- #{dynamic_text}" if dynamic_text
                end
              end
            end

            parts.join("\n")
          end
        end
      end
    end
  end
end
