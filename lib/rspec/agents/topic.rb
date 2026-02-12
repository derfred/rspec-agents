module RSpec
  module Agents
    # Wraps a single expectation with its type, mode, and data
    class TopicExpectation
      attr_reader :type, :mode, :data

      def initialize(type, mode, data)
        @type = type  # :quality, :match, :no_match, :grounding, :tool_call, :forbidden_tool, :forbidden_claims, :custom
        @mode = mode  # :soft or :hard
        @data = data  # Type-specific data hash
      end

      def soft?
        @mode == :soft
      end

      def hard?
        @mode == :hard
      end
    end

    # Represents a distinct phase or state in a conversation
    # Each topic has characteristics, triggers, invariants, and an intent
    class Topic
      attr_reader :name, :triggers, :invariants
      attr_accessor :successors  # Set by TopicGraph

      def initialize(name, &block)
        @name = name.to_sym
        @characteristic_text = nil
        @agent_intent_text = nil
        @triggers = Triggers.new
        @invariants = InvariantSet.new
        @successors = []

        instance_eval(&block) if block_given?
      end

      # DSL: Set the topic's characteristic description
      # Used by LLM judge to identify when conversation is in this topic
      def characteristic(text)
        @characteristic_text = text.strip
      end

      # DSL: Set the agent's intended behavior during this topic
      def agent_intent(text)
        @agent_intent_text = text.strip
      end

      # DSL: Define triggers for deterministic topic classification
      def triggers(&block)
        if block_given?
          @triggers = Triggers.new(&block)
        else
          @triggers
        end
      end

      # DSL: Expect agent to satisfy criteria (hard)
      # @param to_satisfy [Array<Symbol>] Criterion names
      # @param to_match [Regexp] Pattern agent response must match
      # @param not_to_match [Regexp] Pattern agent response must NOT match
      def expect_agent(to_satisfy: nil, to_match: nil, not_to_match: nil)
        @invariants.add_expectation(:quality, :hard, { criteria: to_satisfy }) if to_satisfy
        @invariants.add_expectation(:match, :hard, { pattern: to_match }) if to_match
        @invariants.add_expectation(:no_match, :hard, { pattern: not_to_match }) if not_to_match
      end

      # DSL: Expect agent claims to be grounded in tool results (hard)
      # @param claim_types [Array<Symbol>] Types of claims (:venues, :pricing, etc.)
      # @param from_tools [Array<Symbol>] Tool names that should provide grounding
      def expect_grounding(*claim_types, from_tools: [])
        @invariants.add_expectation(:grounding, :hard, { claim_types: claim_types, from_tools: from_tools })
      end

      # DSL: Forbid agent from making ungrounded claims (hard)
      # @param claim_types [Array<Symbol>] Types of claims to forbid
      def forbid_claims(*claim_types)
        @invariants.add_expectation(:forbidden_claims, :hard, { claim_types: claim_types })
      end

      # DSL: Expect agent to call a specific tool (hard)
      # @param tool_name [Symbol] Tool name
      def expect_tool_call(tool_name)
        @invariants.add_expectation(:tool_call, :hard, { tool_name: tool_name })
      end

      # DSL: Forbid agent from calling a specific tool (hard)
      # @param tool_name [Symbol] Tool name
      def forbid_tool_call(tool_name)
        @invariants.add_expectation(:forbidden_tool, :hard, { tool_name: tool_name })
      end

      # DSL: Custom expectation with block (hard)
      # @param description [String] Description of expectation
      # @yield [turn, conversation] Block that returns true/false
      def expect(description, &block)
        @invariants.add_expectation(:custom, :hard, { description: description, block: block })
      end

      # DSL: Soft evaluation - quality criteria
      # @param to_satisfy [Array<Symbol>] Criterion names
      # @param to_match [Regexp] Pattern agent response must match
      # @param not_to_match [Regexp] Pattern agent response must NOT match
      def evaluate_agent(to_satisfy: nil, to_match: nil, not_to_match: nil)
        @invariants.add_expectation(:quality, :soft, { criteria: to_satisfy }) if to_satisfy
        @invariants.add_expectation(:match, :soft, { pattern: to_match }) if to_match
        @invariants.add_expectation(:no_match, :soft, { pattern: not_to_match }) if not_to_match
      end

      # DSL: Soft evaluation - grounding
      # @param claim_types [Array<Symbol>] Types of claims (:venues, :pricing, etc.)
      # @param from_tools [Array<Symbol>] Tool names that should provide grounding
      def evaluate_grounding(*claim_types, from_tools: [])
        @invariants.add_expectation(:grounding, :soft, { claim_types: claim_types, from_tools: from_tools })
      end

      # DSL: Soft evaluation - tool calls
      # @param tool_name [Symbol] Tool name
      def evaluate_tool_call(tool_name)
        @invariants.add_expectation(:tool_call, :soft, { tool_name: tool_name })
      end

      # DSL: Soft evaluation - custom
      # @param description [String] Description of expectation
      # @yield [turn, conversation] Block that returns true/false
      def evaluate(description, &block)
        @invariants.add_expectation(:custom, :soft, { description: description, block: block })
      end

      attr_reader :characteristic_text

      attr_reader :agent_intent_text

      def trigger_matches?(turn, conversation)
        @triggers.any_match?(turn, conversation)
      end

      # Evaluate all invariants for turns that occurred in this topic
      # @param turns [Array] Turns that occurred in this topic
      # @param conversation [Object] Full conversation context
      # @param judge [Object] LLM judge for evaluating quality/grounding
      # @return [InvariantResults]
      def evaluate_invariants(turns, conversation, judge)
        @invariants.evaluate(turns, conversation, judge, @name)
      end

      def to_h
        {
          name:           @name,
          characteristic: @characteristic_text,
          agent_intent:   @agent_intent_text,
          successors:     @successors
        }
      end
    end

    # Collects and evaluates invariants for a topic
    class InvariantSet
      def initialize
        @expectations = []  # Array of TopicExpectation objects
      end

      # Generic method to add any type of expectation
      def add_expectation(type, mode, data)
        @expectations << TopicExpectation.new(type, mode, data)
      end

      def empty?
        @expectations.empty?
      end

      # Evaluate all invariants against the given turns
      # @return [InvariantResults]
      def evaluate(turns, conversation, judge, topic_name)
        results = InvariantResults.new(topic_name)

        @expectations.each do |expectation|
          case expectation.type
          when :quality
            # LLM-based evaluation - mark as pending
            results.add_pending(:quality, expectation.data[:criteria], mode: expectation.mode)

          when :match
            # Pattern matching - deterministic
            pattern = expectation.data[:pattern]
            matched = turns.any? { |t| pattern.match?(t.agent_response&.text.to_s) }
            results.add(
              :match,
              pattern.inspect,
              matched,
              matched ? nil : "No response matched #{pattern.inspect}",
              mode: expectation.mode
            )

          when :no_match
            # Forbidden pattern - deterministic
            pattern = expectation.data[:pattern]
            violated = turns.any? { |t| pattern.match?(t.agent_response&.text.to_s) }
            results.add(
              :no_match,
              pattern.inspect,
              !violated,
              violated ? "Response matched forbidden pattern #{pattern.inspect}" : nil,
              mode: expectation.mode
            )

          when :tool_call
            # Tool call expectation - deterministic
            all_tool_calls = turns.flat_map { |t| t.agent_response&.tool_calls || [] }
            tool_name = expectation.data[:tool_name]
            called = all_tool_calls.any? { |tc| tc.name == tool_name }
            results.add(
              :tool_call,
              tool_name,
              called,
              called ? nil : "Expected tool call to #{tool_name} but it was not called",
              mode: expectation.mode
            )

          when :forbidden_tool
            # Forbidden tool - deterministic
            all_tool_calls = turns.flat_map { |t| t.agent_response&.tool_calls || [] }
            tool_name = expectation.data[:tool_name]
            called = all_tool_calls.any? { |tc| tc.name == tool_name }
            results.add(
              :forbidden_tool,
              tool_name,
              !called,
              called ? "Forbidden tool #{tool_name} was called" : nil,
              mode: expectation.mode
            )

          when :grounding
            # LLM-based evaluation - mark as pending
            results.add_pending(:grounding, expectation.data, mode: expectation.mode)

          when :forbidden_claims
            # LLM-based evaluation - mark as pending
            results.add_pending(:forbidden_claims, expectation.data[:claim_types], mode: expectation.mode)

          when :custom
            # Code-based evaluation - deterministic
            passed = turns.all? { |turn| expectation.data[:block].call(turn, conversation) }
            results.add(
              :custom,
              expectation.data[:description],
              passed,
              passed ? nil : "Custom expectation failed: #{expectation.data[:description]}",
              mode: expectation.mode
            )
          end
        end

        results
      end
    end

    # Stores results of invariant evaluation
    class InvariantResults
      attr_reader :topic_name, :results, :pending

      def initialize(topic_name)
        @topic_name = topic_name
        @results = []
        @pending = []  # Requires judge evaluation
      end

      def add(type, description, passed, failure_message, mode: :hard)
        @results << {
          type:            type,
          description:     description,
          passed:          passed,
          failure_message: failure_message,
          mode:            mode
        }
      end

      def add_pending(type, data, mode: :hard)
        @pending << { type: type, data: data, mode: mode }
      end

      def passed?
        # Only check hard expectations
        @results.select { |r| r[:mode] == :hard }.all? { |r| r[:passed] } &&
          @pending.select { |p| p[:mode] == :hard }.empty?
      end

      def failures
        # Only return hard failures
        @results.reject { |r| r[:passed] || r[:mode] == :soft }
      end

      def soft_failures
        @results.select { |r| !r[:passed] && r[:mode] == :soft }
      end

      def hard_failures
        @results.select { |r| !r[:passed] && r[:mode] == :hard }
      end

      def has_pending?
        !@pending.empty?
      end
    end
  end
end
