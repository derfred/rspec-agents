module RSpec
  module Agents
    # Executes a single conversation turn: send user message, get agent response, classify topic
    # This is the core execution unit shared between scripted tests and simulated conversations
    class TurnExecutor
      attr_reader :current_response, :current_turn, :conversation
      attr_accessor :graph

      # @param agent [Agents::Base] The agent under test
      # @param conversation [Conversation] The conversation to operate on
      # @param graph [TopicGraph, nil] Optional topic graph for topic tracking
      # @param judge [Judge, nil] Optional judge for topic classification
      # @param event_bus [EventBus, nil] Optional event bus for emitting events
      def initialize(agent:, conversation:, graph: nil, judge: nil, event_bus: nil)
        @agent = agent
        @conversation = conversation
        @graph = graph
        @judge = judge
        @event_bus = event_bus
        @current_response = nil
        @current_turn = nil

        # Initialize topic if graph provided and conversation has no topic yet
        if @graph && @graph.initial_topic && @conversation.current_topic.nil?
          @conversation.set_topic(@graph.initial_topic, trigger: :initial)
        end
      end

      # Execute a turn: add user message, get agent response, optionally classify topic
      #
      # @param text [String] The user's message
      # @param source [Symbol] Message source (:script or :simulator)
      # @param metadata [Hash] Optional metadata for the message
      # @return [AgentResponse] The agent's response
      def execute(text, source: :script, metadata: {})
        @conversation.add_user_message(text, metadata: metadata, source: source)

        # Get agent response
        messages = @conversation.messages_for_agent
        @current_response = @agent.chat(messages, on_tool_call: method(:handle_tool_call))

        # Record turn
        @current_turn = @conversation.add_agent_response(@current_response)

        # Classify topic if graph provided
        classify_current_turn if @graph

        @current_response
      end

      # Get the current topic from the conversation
      #
      # @return [Symbol, nil]
      def current_topic
        @conversation.current_topic
      end

      # Get tool calls from the current response, optionally filtered by name
      # @param name [Symbol, String, nil] Optional tool name to filter by
      # @return [Array<ToolCall>]
      def tool_calls(name = nil)
        calls = @current_response&.tool_calls || []
        name ? calls.select { |tc| tc.name == name.to_sym } : calls
      end

      # Check if current turn is in expected topic
      #
      # @param expected_topic [Symbol] Expected topic name
      # @return [Boolean]
      def in_topic?(expected_topic)
        current_topic == expected_topic.to_sym
      end

      private

      def handle_tool_call(tool_call)
        @event_bus&.publish(Events::ToolCallCompleted.new(
          example_id:  Thread.current[:rspec_agents_example_id],
          turn_number: @conversation.turns.size + 1,
          tool_name:   tool_call.name,
          arguments:   tool_call.arguments,
          result:      tool_call.result,
          time:        Time.now
        ))
      end

      def classify_current_turn
        return unless @graph && @current_turn

        current_topic_name = @conversation.current_topic
        new_topic = @graph.classify(@current_turn, @conversation, current_topic_name, judge: @judge)

        if new_topic != current_topic_name
          @conversation.set_topic(new_topic, trigger: :classification)
        end
        @current_turn.topic = new_topic
      end
    end
  end
end
