module RSpec
  module Agents
    # Tracks the state of a conversation during test execution
    # Maintains messages, turns, and topic history
    class Conversation
      attr_reader :messages, :turns, :topic_history, :evaluation_results

      # @param event_bus [EventBus, nil] Optional event bus for emitting events
      def initialize(event_bus: nil)
        @event_bus = event_bus
        @example_id = Thread.current[:rspec_agents_example_id]
        @messages = []
        @turns = []
        @topic_history = []  # Array of { topic: Symbol, turns: Array<Turn> }
        @current_topic = nil
        @turns_per_topic = Hash.new(0)
        @evaluation_results = []  # Array of EvaluationResult objects
      end

      def conversation
        self
      end

      # Add a user message to the conversation
      #
      # @param text [String] Message text
      # @param metadata [Hash] Optional metadata
      # @param source [Symbol] Message source (:simulator, :script, :unknown)
      # @return [Message] The added message
      def add_user_message(text, metadata: {}, source: :unknown)
        message = Message.new(
          role:     :user,
          content:  text,
          metadata: metadata
        )
        @messages << message

        emit(Events::UserMessage.new(
          example_id:  @example_id,
          turn_number: @turns.size + 1,
          text:        text,
          source:      source,
          time:        Time.now
        ))

        message
      end

      # Add an agent response to the conversation
      # Creates a turn with the last user message
      #
      # @param response [AgentResponse] The agent's response
      # @return [Turn] The created turn
      def add_agent_response(response)
        message = Message.new(
          role:       :agent,
          content:    response.text,
          tool_calls: response.tool_calls,
          metadata:   response.metadata.to_h
        )
        @messages << message

        # Find the last user message to pair with this response
        last_user_msg = @messages.reverse.find(&:user?)
        last_user_message = last_user_msg&.content

        # Create turn
        turn = Turn.new(last_user_message, response, topic: @current_topic)
        @turns << turn

        # Update topic tracking
        if @current_topic
          @turns_per_topic[@current_topic] += 1
          add_turn_to_topic_history(turn)
        end

        emit(Events::AgentResponse.new(
          example_id:  @example_id,
          turn_number: @turns.size,
          text:        response.text,
          tool_calls:  response.tool_calls.map { |tc| tc.respond_to?(:to_h) ? tc.to_h : tc },
          metadata:    response.metadata.respond_to?(:to_h) ? response.metadata.to_h : (response.metadata || {}),
          time:        Time.now
        ))

        turn
      end

      # Set the current topic
      #
      # @param topic_name [Symbol] The topic name
      # @param trigger [Symbol, nil] What triggered the topic change
      def set_topic(topic_name, trigger: nil)
        return if @current_topic == topic_name

        previous = @current_topic
        @current_topic = topic_name

        # Start new topic history entry
        @topic_history << { topic: topic_name, turns: [] }

        emit(Events::TopicChanged.new(
          example_id:  @example_id,
          turn_number: @turns.size,
          from_topic:  previous,
          to_topic:    topic_name,
          trigger:     trigger || :unknown,
          time:        Time.now
        ))
      end

      # Get the current topic
      #
      # @return [Symbol, nil]
      attr_reader :current_topic

      # Get the number of turns that have occurred in a specific topic
      #
      # @param topic_name [Symbol] The topic name
      # @return [Integer]
      def turns_in_topic(topic_name)
        @turns_per_topic[topic_name.to_sym]
      end

      # Get all turns that occurred in a specific topic
      #
      # @param topic_name [Symbol] The topic name
      # @return [Array<Turn>]
      def turns_for_topic(topic_name)
        entry = @topic_history.find { |h| h[:topic] == topic_name }
        entry ? entry[:turns] : []
      end

      # Get all tool calls across all turns
      #
      # @return [Array<ToolCall>]
      def all_tool_calls
        @turns.flat_map(&:tool_calls)
      end

      # Check if a specific tool was called
      #
      # @param name [Symbol, String] Tool name
      # @return [Boolean]
      def has_tool_call?(name)
        all_tool_calls.any? { |tc| tc.name == name.to_sym }
      end

      # Count how many times a tool was called
      #
      # @param name [Symbol, String] Tool name
      # @return [Integer]
      def called_tool?(name)
        all_tool_calls.count { |tc| tc.name == name.to_sym }
      end

      # Find tool calls by name
      #
      # @param name [Symbol, String] Tool name
      # @param params [Hash, nil] Optional parameter filter
      # @return [Array<ToolCall>]
      def find_tool_calls(name, params: nil)
        calls = all_tool_calls.select { |tc| tc.name == name.to_sym }
        return calls unless params

        calls.select { |tc| tc.matches_params?(params) }
      end

      # Get the last agent response
      #
      # @return [AgentResponse, nil]
      def last_agent_response
        @turns.last&.agent_response
      end

      # Get the last user message
      #
      # @return [String, nil]
      def last_user_message
        @messages.reverse.find(&:user?)&.content
      end

      # Get the last turn
      #
      # @return [Turn, nil]
      def last_turn
        @turns.last
      end

      # Get the number of turns
      #
      # @return [Integer]
      def turn_count
        @turns.count
      end

      # Check if conversation is empty
      #
      # @return [Boolean]
      def empty?
        @messages.empty?
      end

      # Record an evaluation result (soft or hard)
      #
      # @param mode [Symbol] :soft or :hard
      # @param type [Symbol] Type of assertion (:quality, :grounding, :tool_call, etc.)
      # @param description [String] Human-readable description
      # @param passed [Boolean] Whether evaluation passed
      # @param failure_message [String, nil] Reason for failure
      # @param metadata [Hash] Additional context
      # @return [EvaluationResult] The recorded result
      def record_evaluation(mode:, type:, description:, passed:, failure_message: nil, metadata: {})
        turn_number = @turns.size
        enriched_metadata = metadata.merge(
          turn_number: turn_number,
          topic:       @current_topic
        )

        result = EvaluationResult.new(
          mode:            mode,
          type:            type,
          description:     description,
          passed:          passed,
          failure_message: failure_message,
          metadata:        enriched_metadata
        )
        @evaluation_results << result

        emit(Events::EvaluationRecorded.new(
          example_id:      @example_id,
          turn_number:     turn_number,
          mode:            mode,
          type:            type,
          description:     description,
          passed:          passed,
          failure_message: failure_message,
          metadata:        metadata,
          time:            Time.now
        ))

        result
      end

      # Get soft evaluation results only
      #
      # @return [Array<EvaluationResult>]
      def soft_evaluations
        @evaluation_results.select(&:soft?)
      end

      # Get hard evaluation results only
      #
      # @return [Array<EvaluationResult>]
      def hard_evaluations
        @evaluation_results.select(&:hard?)
      end

      # Format messages for sending to agent
      # Returns messages in the format expected by agent adapters
      # Note: role is converted to string for API compatibility
      #
      # @return [Array<Hash>]
      def messages_for_agent
        @messages.map do |m|
          { role: m.role.to_s, content: m.content }
        end
      end

      # Reset the conversation state
      def reset!
        @messages.clear
        @turns.clear
        @topic_history.clear
        @current_topic = nil
        @turns_per_topic.clear
        @evaluation_results.clear
      end

      def to_h
        {
          messages:           @messages.map(&:to_h),
          turns:              @turns.map(&:to_h),
          topic_history:      @topic_history,
          current_topic:      @current_topic,
          evaluation_results: @evaluation_results.map(&:to_h)
        }
      end

      def inspect
        "#<#{self.class.name} turns=#{@turns.count} messages=#{@messages.count}>"
      end

      private

      def emit(event)
        @event_bus&.publish(event)
      end

      def add_turn_to_topic_history(turn)
        return if @topic_history.empty?

        current_entry = @topic_history.last
        current_entry[:turns] << turn if current_entry[:topic] == @current_topic
      end
    end
  end
end
