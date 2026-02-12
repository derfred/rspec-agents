# frozen_string_literal: true

module RSpec
  module Agents
    module Serialization
      # Builds RunData by subscribing to EventBus events.
      # Thread-safe for parallel event arrival.
      #
      # Works identically in single-process and parallel (controller) modes -
      # it just subscribes to whatever EventBus is available.
      class RunDataBuilder < Observers::Base
        attr_reader :run_data

        def initialize(event_bus: EventBus.instance)
          @mutex = Mutex.new
          @current_turns = {}
          @run_data = nil
          super(event_bus: event_bus)
        end

        def on_suite_started(event)
          @mutex.synchronize do
            # In parallel mode, multiple workers will send SuiteStarted events
            # Only create RunData once - ignore subsequent SuiteStarted events
            return if @run_data

            @run_data = RunData.new(
              run_id: SecureRandom.uuid,
              started_at: event.time,
              seed: event.seed,
              git_commit: GitHelpers.current_commit
            )
          end
        end

        def on_suite_stopped(event)
          @mutex.synchronize { @run_data.finished_at = event.time if @run_data }
        end

        def on_example_started(event)
          @mutex.synchronize do
            return unless @run_data
            file = event.location.to_s.split(":").first

            # Register scenario if present and get its ID
            scenario_id = nil
            if event.respond_to?(:scenario) && event.scenario
              scenario_data = ScenarioData.from_scenario(event.scenario)
              scenario_id = @run_data.register_scenario(scenario_data)
            end

            example_data = ExampleData.new(
              id:             event.example_id,
              stable_id:      event.stable_id,
              canonical_path: event.canonical_path,
              scenario_id:    scenario_id,
              file:           file,
              description:    event.description,
              location:       event.location,
              status:         :running,
              started_at:     event.time
            )
            @run_data.add_example(example_data)
            example_data.conversation = ConversationData.new(started_at: event.time)
          end
        end

        def on_example_passed(event)
          @mutex.synchronize do
            return unless @run_data
            example = @run_data.example(event.example_id)
            return unless example
            finalize_pending_turn(event.example_id, event.time)
            example.status = :passed
            example.finished_at = event.time
            example.duration_ms = (event.duration * 1000).to_i if event.duration
            example.conversation&.ended_at = event.time
            example.conversation.final_topic = example.conversation.turns.last&.topic if example.conversation
          end
        end

        def on_example_failed(event)
          @mutex.synchronize do
            return unless @run_data
            example = @run_data.example(event.example_id)
            return unless example
            finalize_pending_turn(event.example_id, event.time)
            example.status = :failed
            example.finished_at = event.time
            example.duration_ms = (event.duration * 1000).to_i if event.duration
            example.conversation&.ended_at = event.time
            if event.message || event.backtrace
              example.exception = ExceptionData.new(
                class_name: "RSpec::Expectations::ExpectationNotMetError",
                message:    event.message,
                backtrace:  event.backtrace || []
              )
            end
            example.conversation.final_topic = example.conversation.turns.last&.topic if example.conversation
          end
        end

        def on_example_pending(event)
          @mutex.synchronize do
            return unless @run_data
            example = @run_data.example(event.example_id)
            example.status = :pending if example
          end
        end

        def on_user_message(event)
          @mutex.synchronize do
            return unless @run_data
            example = @run_data.example(event.example_id)
            return unless example&.conversation
            finalize_pending_turn(event.example_id, event.time)
            user_message = MessageData.new(role: :user, content: event.text, timestamp: event.time, source: event.source)
            @current_turns[event.example_id] = TurnData.new(number: event.turn_number, user_message: user_message)
          end
        end

        def on_agent_response(event)
          @mutex.synchronize do
            return unless @run_data
            example = @run_data.example(event.example_id)
            return unless example&.conversation
            current_turn = @current_turns[event.example_id]
            return unless current_turn

            metadata = case event.metadata
                       when Metadata then event.metadata
                       when Hash then Metadata.new(event.metadata)
                       else Metadata.new
                       end
            current_turn.agent_response = MessageData.new(role: :agent, content: event.text, timestamp: event.time, metadata: metadata)
            current_turn.tool_calls = (event.tool_calls || []).map do |tc|
              tc_hash = tc.respond_to?(:to_h) ? tc.to_h : tc
              ToolCallData.new(
                name:      tc_hash[:name] || tc_hash["name"],
                arguments: tc_hash[:arguments] || tc_hash["arguments"] || {},
                result:    tc_hash[:result] || tc_hash["result"],
                error:     tc_hash[:error] || tc_hash["error"],
                timestamp: event.time,
                metadata:  tc_hash[:metadata] || tc_hash["metadata"] || {}
              )
            end
          end
        end

        def on_topic_changed(event)
          @mutex.synchronize do
            return unless @run_data
            current_turn = @current_turns[event.example_id]
            current_turn.topic = event.to_topic if current_turn
          end
        end

        def on_tool_call_completed(event)
          # No-op: AgentResponse is canonical source for tool calls
        end

        def on_evaluation_recorded(event)
          @mutex.synchronize do
            return unless @run_data
            example = @run_data.example(event.example_id)
            return unless example

            evaluation = EvaluationData.new(
              name:            event.description,
              description:     event.description,
              passed:          event.passed,
              reasoning:       nil,
              timestamp:       event.time,
              mode:            event.mode,
              type:            event.type,
              failure_message: event.failure_message,
              metadata:        event.metadata || {}
            )
            example.add_evaluation(evaluation)
          end
        end

        private

        def finalize_pending_turn(example_id, time)
          current_turn = @current_turns.delete(example_id)
          return unless current_turn
          example = @run_data.example(example_id)
          example&.conversation&.add_turn(current_turn)
        end
      end
    end
  end
end
