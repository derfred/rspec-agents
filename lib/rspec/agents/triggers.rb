module RSpec
  module Agents
    # Enables deterministic topic classification without LLM calls
    # When a trigger matches, the topic is classified without invoking the judge
    class Triggers
      def initialize(&block)
        @triggers = []
        instance_eval(&block) if block_given?
      end

      # Trigger when agent calls a specific tool
      # @param name [Symbol] Tool name
      # @param with_params [Hash] Optional parameter constraints (values can be Regexp or exact match)
      def on_tool_call(name, with_params: nil)
        @triggers << ToolCallTrigger.new(name, with_params)
      end

      # Trigger when agent response matches a pattern
      # @param pattern [Regexp] Pattern to match against agent response text
      def on_response_match(pattern)
        @triggers << ResponseMatchTrigger.new(pattern)
      end

      # Trigger when user message matches a pattern
      # @param pattern [Regexp] Pattern to match against user message text
      def on_user_match(pattern)
        @triggers << UserMatchTrigger.new(pattern)
      end

      # Trigger after N turns in a specific topic
      # @param topic [Symbol] Topic name
      # @param count [Integer] Number of turns
      def after_turns_in(topic, count:)
        @triggers << TurnsInTopicTrigger.new(topic, count)
      end

      # Trigger on custom condition
      # @param condition [Proc] Lambda receiving (turn, conversation)
      def on_condition(condition)
        @triggers << ConditionTrigger.new(condition)
      end

      # Check if any trigger matches the current turn
      # @param turn [Object] Current turn (has agent_response, user_message)
      # @param conversation [Object] Full conversation context
      # @return [Boolean]
      def any_match?(turn, conversation)
        @triggers.any? { |trigger| trigger.match?(turn, conversation) }
      end

      def empty?
        @triggers.empty?
      end

      def count
        @triggers.count
      end

      # Individual trigger types

      class ToolCallTrigger
        def initialize(name, params)
          @name = name.to_sym
          @params = params
        end

        def match?(turn, _conversation)
          return false unless turn.respond_to?(:agent_response) && turn.agent_response

          turn.agent_response.has_tool_call?(@name, params: @params)
        end
      end

      class ResponseMatchTrigger
        def initialize(pattern)
          @pattern = pattern
        end

        def match?(turn, _conversation)
          return false unless turn.respond_to?(:agent_response) && turn.agent_response

          @pattern.match?(turn.agent_response.text.to_s)
        end
      end

      class UserMatchTrigger
        def initialize(pattern)
          @pattern = pattern
        end

        def match?(turn, _conversation)
          return false unless turn.respond_to?(:user_message)

          @pattern.match?(turn.user_message.to_s)
        end
      end

      class TurnsInTopicTrigger
        def initialize(topic, count)
          @topic = topic.to_sym
          @count = count
        end

        def match?(_turn, conversation)
          return false unless conversation.respond_to?(:turns_in_topic)

          conversation.turns_in_topic(@topic) >= @count
        end
      end

      class ConditionTrigger
        def initialize(condition)
          @condition = condition
        end

        def match?(turn, conversation)
          @condition.call(turn, conversation)
        end
      end
    end
  end
end
