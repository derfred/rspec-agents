module RSpec
  module Agents
    module DSL
      # Proxy for agent state inspection in scripted tests
      # Provides read-only access to turn executor state and assertion helpers
      class AgentProxy
        # @param turn_executor [TurnExecutor]
        # @param judge [Judge, nil] Optional judge for LLM-based assertions
        def initialize(turn_executor:, judge: nil)
          @turn_executor = turn_executor
          @judge         = judge
        end

        # Get the turn executor (runner)
        # @return [TurnExecutor]
        def runner
          @turn_executor
        end

        # Get the conversation (delegates to turn executor)
        # @return [Conversation]
        def conversation
          @turn_executor.conversation
        end

        # Get the current response object
        # @return [AgentResponse, nil]
        def response
          @turn_executor.current_response
        end

        # Get the response text
        # @return [String, nil]
        def last_response
          response&.text
        end

        # Get the current topic
        # @return [Symbol, nil]
        def current_topic
          @turn_executor.current_topic
        end

        # Get the current turn
        # @return [Turn, nil]
        def current_turn
          @turn_executor.current_turn
        end

        # Get tool calls from current response
        # @return [Array<ToolCall>]
        def tool_calls
          response&.tool_calls || []
        end

        # Check if agent called a specific tool
        # @param name [Symbol, String]
        # @param params [Hash, nil]
        # @return [Boolean]
        def called_tool?(name, params: nil)
          response&.has_tool_call?(name, params: params) || false
        end

        # Check if in a specific topic
        # @param topic_name [Symbol]
        # @return [Boolean]
        def in_topic?(topic_name)
          @turn_executor.in_topic?(topic_name)
        end

        # Check if current response matches a pattern
        #
        # @param pattern [Regexp] Pattern to match
        # @return [Boolean]
        def response_matches?(pattern)
          response&.match?(pattern) || false
        end

        # Evaluate a criterion against the current turn
        # Uses the Criterion class to normalize and evaluate all criterion types
        #
        # @param criterion [Symbol, String, Proc, Criterion] Criterion to evaluate
        # @return [Hash] { satisfied: Boolean, reasoning: String }
        def evaluate_criterion(criterion)
          turn = current_turn
          return { satisfied: false, reasoning: "No turn to evaluate" } unless turn

          # Normalize to Criterion object
          criterion_obj = criterion.is_a?(Criterion) ? criterion : Criterion.from(criterion)

          criterion_obj.evaluate(
            turn:              turn,
            judge:             @judge,
            conversation:      conversation,
            criteria_registry: @judge&.criteria || {}
          )
        end

        # Check if response is grounded in tool results
        #
        # @param claim_types [Array<Symbol>] Claim types to verify
        # @param from_tools [Array<Symbol>] Tool names that should provide grounding
        # @return [Hash] { grounded: Boolean, violations: Array }
        def check_grounding(claim_types, from_tools: [])
          return { grounded: true, violations: [] } unless @judge

          turn = current_turn
          return { grounded: false, violations: ["No turn to evaluate"] } unless turn

          @judge.evaluate_grounding(claim_types, [turn], from_tools: from_tools)
        end

        # Check for forbidden claims
        #
        # @param claim_types [Array<Symbol>] Claim types that are forbidden
        # @return [Hash] { violated: Boolean, claims_found: Array }
        def check_forbidden_claims(claim_types)
          return { violated: false, claims_found: [] } unless @judge

          turn = current_turn
          return { violated: false, claims_found: [] } unless turn

          @judge.evaluate_forbidden_claims(claim_types, [turn])
        end

        # Check if agent demonstrates expected intent
        #
        # @param intent_description [String] Description of expected intent
        # @return [Hash] { matches: Boolean, observed_intent: String, reasoning: String }
        def check_intent(intent_description)
          return { matches: false, reasoning: "No judge configured" } unless @judge

          turn = current_turn
          return { matches: false, reasoning: "No turn to evaluate" } unless turn

          @judge.evaluate_intent(intent_description, turn)
        end
      end
    end
  end
end
