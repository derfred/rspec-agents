module RSpec
  module Agents
    # LLM-as-judge for evaluating agent responses
    # Handles quality criteria, grounding verification, intent assessment, and topic classification
    class Judge
      attr_reader :llm, :criteria

      # @param llm [LLM::Base] LLM adapter for making evaluation calls
      # @param criteria [Hash<Symbol, CriterionDefinition>] Available criteria definitions
      def initialize(llm:, criteria: {})
        @llm = llm
        @criteria = criteria
      end

      # Classify which topic a turn belongs to
      # Uses LLM to analyze the turn and determine the appropriate topic
      #
      # @param turn [Turn] The turn to classify
      # @param conversation [Conversation] Full conversation context
      # @param possible_topics [Array<Topic>] Topics that could apply
      # @return [Symbol] The classified topic name
      def classify_topic(turn, conversation, possible_topics)
        return possible_topics.first.name if possible_topics.size == 1

        prompt   = PromptBuilders::TopicClassification.build(turn, conversation, possible_topics)
        response = @llm.complete(prompt, response_format: :json)
        result   = PromptBuilders::TopicClassification.parse(response, possible_topics.map(&:name))

        result[:topic]
      end

      # Evaluate whether turns satisfy a quality criterion
      #
      # @param criterion [Symbol, CriterionDefinition] Criterion name or definition
      # @param turns [Array<Turn>] Turns to evaluate
      # @param conversation [Conversation] Full conversation context
      # @return [Hash] { satisfied: Boolean, reasoning: String }
      def evaluate_criterion(criterion, turns, conversation)
        criterion_def = resolve_criterion(criterion)
        return { satisfied: false, reasoning: "Unknown criterion: #{criterion}" } unless criterion_def

        # If criterion has code-based evaluation, use it
        if criterion_def.code_based?
          return evaluate_code_criterion(criterion_def, turns, conversation)
        end

        # Otherwise use LLM evaluation
        context = build_evaluation_context(conversation)
        prompt = PromptBuilders::CriterionEvaluation.build(criterion_def, turns, context)
        response = @llm.complete(prompt, response_format: :json)

        PromptBuilders::CriterionEvaluation.parse(response)
      end

      # Evaluate whether agent claims are grounded in tool results
      #
      # @param claim_types [Array<Symbol>] Types of claims to verify
      # @param turns [Array<Turn>] Turns to evaluate
      # @param from_tools [Array<Symbol>] Tool names that should provide grounding
      # @return [Hash] { grounded: Boolean, violations: Array<String> }
      def evaluate_grounding(claim_types, turns, from_tools: [])
        # Collect agent text and tool calls from turns
        agent_texts = turns.map { |t| t.agent_response&.text }.compact
        all_tool_calls = turns.flat_map { |t| t.agent_response&.tool_calls || [] }

        # Filter to specified tools if provided
        if from_tools.any?
          all_tool_calls = all_tool_calls.select { |tc| from_tools.include?(tc.name) }
        end

        combined_text = agent_texts.join("\n\n")
        prompt = PromptBuilders::GroundingEvaluation.build(
          claim_types,
          combined_text,
          all_tool_calls,
          mode: :expect_grounded
        )
        response = @llm.complete(prompt, response_format: :json)

        PromptBuilders::GroundingEvaluation.parse(response, mode: :expect_grounded)
      end

      # Evaluate whether agent makes forbidden ungrounded claims
      #
      # @param claim_types [Array<Symbol>] Types of claims that are forbidden
      # @param turns [Array<Turn>] Turns to evaluate
      # @return [Hash] { violated: Boolean, claims_found: Array }
      def evaluate_forbidden_claims(claim_types, turns)
        agent_texts = turns.map { |t| t.agent_response&.text }.compact
        all_tool_calls = turns.flat_map { |t| t.agent_response&.tool_calls || [] }

        combined_text = agent_texts.join("\n\n")
        prompt = PromptBuilders::GroundingEvaluation.build(
          claim_types,
          combined_text,
          all_tool_calls,
          mode: :forbid_claims
        )
        response = @llm.complete(prompt, response_format: :json)

        PromptBuilders::GroundingEvaluation.parse(response, mode: :forbid_claims)
      end

      # Evaluate whether agent demonstrates expected intent
      #
      # @param intent_description [String] Description of expected intent
      # @param turn [Turn] The turn to evaluate
      # @param context [Hash] Additional context
      # @return [Hash] { matches: Boolean, observed_intent: String, reasoning: String }
      def evaluate_intent(intent_description, turn, context = {})
        prompt = PromptBuilders::IntentEvaluation.build(intent_description, turn, context)
        response = @llm.complete(prompt, response_format: :json)

        PromptBuilders::IntentEvaluation.parse(response)
      end

      # Evaluate whether a conversation achieved a stated goal
      #
      # @param goal_description [String] Description of the goal
      # @param conversation [Conversation] The conversation to evaluate
      # @return [Hash] { achieved: Boolean, reasoning: String }
      def evaluate_goal_achievement(goal_description, conversation)
        prompt = PromptBuilders::GoalAchievementEvaluation.build(goal_description, conversation)
        response = @llm.complete(prompt, response_format: :json)

        PromptBuilders::GoalAchievementEvaluation.parse(response)
      end

      # Resolve pending invariant evaluations
      # Called by Topic when evaluating invariants that require LLM
      #
      # @param pending [Array<Hash>] Pending evaluations from InvariantResults
      # @param turns [Array<Turn>] Turns in the topic
      # @param conversation [Conversation] Full conversation context
      # @return [Array<Hash>] Results for each pending evaluation
      def resolve_pending_invariants(pending, turns, conversation)
        pending.map do |item|
          mode = item[:mode] || :hard  # Default to hard for backward compatibility

          case item[:type]
          when :quality
            # item[:data] is array of criterion names
            criteria_names = item[:data]
            results = criteria_names.map do |name|
              evaluate_criterion(name, turns, conversation)
            end
            all_satisfied = results.all? { |r| r[:satisfied] }
            reasons = results.reject { |r| r[:satisfied] }.map { |r| r[:reasoning] }

            {
              type:            :quality,
              description:     criteria_names.join(", "),
              passed:          all_satisfied,
              failure_message: all_satisfied ? nil : "Criteria not satisfied: #{reasons.join('; ')}",
              mode:            mode
            }

          when :grounding
            # item[:data] is { claim_types: [...], from_tools: [...] }
            result = evaluate_grounding(
              item[:data][:claim_types],
              turns,
              from_tools: item[:data][:from_tools]
            )
            {
              type:            :grounding,
              description:     "Grounding: #{item[:data][:claim_types].join(', ')}",
              passed:          result[:grounded],
              failure_message: result[:grounded] ? nil : "Ungrounded claims: #{result[:violations].join(', ')}",
              mode:            mode
            }

          when :forbidden_claims
            # item[:data] is array of forbidden claim types
            result = evaluate_forbidden_claims(item[:data], turns)
            {
              type:            :forbidden_claims,
              description:     "Forbid claims: #{item[:data].join(', ')}",
              passed:          !result[:violated],
              failure_message: result[:violated] ? "Forbidden claims found: #{result[:claims_found].map { |c| c['claim'] }.join(', ')}" : nil,
              mode:            mode
            }

          else
            {
              type:            item[:type],
              description:     "Unknown evaluation type",
              passed:          true,
              failure_message: nil,
              mode:            mode
            }
          end
        end
      end

      private

      def resolve_criterion(criterion)
        case criterion
        when Symbol
          @criteria[criterion]
        when String
          @criteria[criterion.to_sym]
        else
          criterion
        end
      end

      def evaluate_code_criterion(criterion_def, turns, conversation)
        if criterion_def.match_block
          # match block receives full conversation
          passed = criterion_def.match_block.call(conversation)
          {
            satisfied: !!passed,
            reasoning: passed ? "Code-based criterion passed" : "Code-based criterion failed"
          }
        elsif criterion_def.match_messages_block
          # match_messages block receives array of messages
          messages = conversation.messages
          passed = criterion_def.match_messages_block.call(messages)
          {
            satisfied: !!passed,
            reasoning: passed ? "Code-based criterion passed" : "Code-based criterion failed"
          }
        else
          { satisfied: false, reasoning: "No evaluation block defined" }
        end
      end

      def build_evaluation_context(conversation)
        context = {}

        # Add tool call summary if any
        all_tool_calls = conversation.turns.flat_map { |t| t.agent_response&.tool_calls || [] }
        if all_tool_calls.any?
          tool_names = all_tool_calls.map(&:name).uniq
          context["Tools called"] = tool_names.join(", ")
        end

        context
      end
    end
  end
end
