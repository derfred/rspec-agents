# frozen_string_literal: true

module RSpec
  module Agents
    module Events
      # ==========================================================================
      # RSpec Suite Lifecycle Events
      # ==========================================================================

      # Emitted when the test suite starts, before any examples run
      SuiteStarted = Data.define(:example_count, :load_time, :seed, :time)

      # Emitted when all examples have finished executing
      SuiteStopped = Data.define(:time)

      # Emitted after the suite with final statistics
      SuiteSummary = Data.define(:duration, :example_count, :failure_count, :pending_count, :time)

      # ==========================================================================
      # RSpec Group Lifecycle Events (describe/context blocks)
      # ==========================================================================

      # Emitted when entering a describe/context block
      GroupStarted = Data.define(:description, :file_path, :line_number, :time)

      # Emitted when exiting a describe/context block
      GroupFinished = Data.define(:description, :time)

      # ==========================================================================
      # RSpec Example Lifecycle Events
      # ==========================================================================

      # Emitted when an individual example (it block) starts
      # @!attribute example_id [String] RSpec native example ID (position-based)
      # @!attribute stable_id [String, nil] Content-based stable ID for cross-experiment comparison
      # @!attribute canonical_path [String, nil] Human-readable path (for debugging)
      # @!attribute scenario [Scenario, nil] Scenario object if this is a scenario-driven test
      ExampleStarted = Data.define(:example_id, :stable_id, :canonical_path, :description, :full_description, :location, :scenario, :time)

      # Emitted when an example passes
      # @!attribute stable_id [String, nil] Content-based stable ID for cross-experiment comparison
      ExamplePassed = Data.define(:example_id, :stable_id, :description, :full_description, :duration, :time)

      # Emitted when an example fails
      # @!attribute stable_id [String, nil] Content-based stable ID for cross-experiment comparison
      # @!attribute location [String] File path with line number (e.g., "spec/foo_spec.rb:42")
      ExampleFailed = Data.define(:example_id, :stable_id, :description, :full_description, :location, :duration, :message, :backtrace, :time)

      # Emitted when an example is pending/skipped
      # @!attribute stable_id [String, nil] Content-based stable ID for cross-experiment comparison
      ExamplePending = Data.define(:example_id, :stable_id, :description, :full_description, :message, :time)

      # ==========================================================================
      # Simulation Lifecycle Events
      # ==========================================================================

      # Emitted when user.simulate begins execution
      SimulationStarted = Data.define(:example_id, :goal, :max_turns, :time)

      # Emitted when user.simulate completes
      SimulationEnded = Data.define(:example_id, :turn_count, :termination_reason, :time)

      # ==========================================================================
      # Conversation Turn Events
      # ==========================================================================

      # Emitted when a user message is added to the conversation
      UserMessage = Data.define(:example_id, :turn_number, :text, :source, :time)

      # Emitted when the agent responds
      AgentResponse = Data.define(:example_id, :turn_number, :text, :tool_calls, :metadata, :time)

      # Emitted when the conversation topic changes
      TopicChanged = Data.define(:example_id, :turn_number, :from_topic, :to_topic, :trigger, :time)

      # ==========================================================================
      # Tool Call Events
      # ==========================================================================

      # Emitted when a tool call completes (real-time signaling from agent)
      ToolCallCompleted = Data.define(:example_id, :turn_number, :tool_name, :arguments, :result, :time)

      # ==========================================================================
      # Evaluation Events
      # ==========================================================================

      # Emitted when an evaluation is recorded (soft or hard)
      # @!attribute mode [Symbol] :soft or :hard
      # @!attribute type [Symbol] Type of assertion (:quality, :grounding, :tool_call, etc.)
      # @!attribute description [String] Human-readable description
      # @!attribute passed [Boolean] Whether evaluation passed
      # @!attribute failure_message [String, nil] Reason for failure
      # @!attribute metadata [Hash] Additional context (criterion names, etc.)
      EvaluationRecorded = Data.define(:example_id, :turn_number, :mode, :type, :description, :passed, :failure_message, :metadata, :time)

      # ==========================================================================
      # Utility: Reconstruct event from type name and payload hash
      # ==========================================================================

      # Maps event type names to their classes for deserialization
      EVENT_TYPES = {
        "SuiteStarted"       => SuiteStarted,
        "SuiteStopped"       => SuiteStopped,
        "SuiteSummary"       => SuiteSummary,
        "GroupStarted"       => GroupStarted,
        "GroupFinished"      => GroupFinished,
        "ExampleStarted"     => ExampleStarted,
        "ExamplePassed"      => ExamplePassed,
        "ExampleFailed"      => ExampleFailed,
        "ExamplePending"     => ExamplePending,
        "SimulationStarted"  => SimulationStarted,
        "SimulationEnded"    => SimulationEnded,
        "UserMessage"        => UserMessage,
        "AgentResponse"      => AgentResponse,
        "TopicChanged"       => TopicChanged,
        "ToolCallCompleted"  => ToolCallCompleted,
        "EvaluationRecorded" => EvaluationRecorded
      }.freeze

      # Reconstruct a typed event from its serialized form
      #
      # @param type_name [String] Event class name (e.g., "ExampleStarted")
      # @param payload [Hash] Event attributes
      # @return [Data, nil] Reconstructed event or nil if unknown type
      def self.from_hash(type_name, payload)
        klass = EVENT_TYPES[type_name]
        return nil unless klass

        # Convert string keys to symbols and filter to known members
        sym_payload = payload.transform_keys(&:to_sym)
        members = klass.members
        filtered = sym_payload.slice(*members)

        klass.new(**filtered)
      rescue ArgumentError => e
        warn "[Events.from_hash] Failed to reconstruct #{type_name}: #{e.message}"
        nil
      end
    end
  end
end
