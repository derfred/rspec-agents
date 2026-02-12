module RSpec
  module Agents
    # Represents the result of a single evaluation (soft or hard)
    # Soft evaluations record quality metrics without affecting test pass/fail
    # Hard evaluations enforce requirements that must be met
    class EvaluationResult
      attr_reader :mode, :type, :description, :passed, :failure_message, :metadata

      # @param mode [Symbol] :soft or :hard
      # @param type [Symbol] Type of assertion (:quality, :grounding, :tool_call, etc.)
      # @param description [String] Human-readable description
      # @param passed [Boolean] Whether evaluation passed
      # @param failure_message [String, nil] Reason for failure
      # @param metadata [Hash] Additional context (turn_number, topic, criterion_name, etc.)
      def initialize(mode:, type:, description:, passed:, failure_message: nil, metadata: {})
        @mode = mode
        @type = type
        @description = description
        @passed = passed
        @failure_message = failure_message
        @metadata = metadata
      end

      def soft?
        @mode == :soft
      end

      def hard?
        @mode == :hard
      end

      def to_h
        {
          mode:            @mode,
          type:            @type,
          description:     @description,
          passed:          @passed,
          failure_message: @failure_message,
          metadata:        @metadata
        }
      end
    end
  end
end
