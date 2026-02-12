module RSpec
  module Agents
    # Unified criterion wrapper that normalizes all criterion types
    #
    # Criterion types:
    # - Named: Symbol referencing a CriterionDefinition in the registry
    # - Adhoc: String description evaluated directly via LLM
    # - Lambda: Proc for code-based evaluation
    #
    # Usage:
    #   Criterion.from(:friendly)                    # Named criterion
    #   Criterion.from("Response is concise")        # Adhoc criterion
    #   Criterion.from(->(turn) { turn.text.length < 100 })  # Lambda criterion
    #   Criterion.from(:concise, ->(turn) { ... })   # Named lambda
    #
    class Criterion
      attr_reader :name, :evaluatable

      # Create criterion from various input types
      #
      # @param args [Array] Arguments to create criterion from
      #   - Symbol: named criterion (looked up from registry)
      #   - String: adhoc criterion (description for LLM)
      #   - Proc: lambda criterion (code-based)
      #   - Symbol + Proc: named lambda criterion
      #   - CriterionDefinition: wrap directly
      # @return [Criterion]
      def self.from(*args)
        case args.length
        when 1
          arg = args.first
          case arg
          when Criterion
            arg
          when Symbol
            new(arg.to_s, arg)
          when String
            new(arg, arg)
          when Proc
            new("lambda", arg)
          when DSL::CriterionDefinition
            new(arg.name.to_s, arg)
          else
            raise ArgumentError, "Cannot create Criterion from #{arg.class}"
          end
        when 2
          name, proc = args
          unless name.is_a?(Symbol) && proc.is_a?(Proc)
            raise ArgumentError, "Expected (Symbol, Proc), got (#{name.class}, #{proc.class})"
          end
          new(name.to_s, proc)
        else
          raise ArgumentError, "Expected 1 or 2 arguments, got #{args.length}"
        end
      end

      # Parse mixed criteria arguments into array of Criterion objects
      #
      # Handles:
      #   [:friendly]                     -> [Criterion(:friendly)]
      #   ["Response is short"]           -> [Criterion("Response is short")]
      #   [->(t) { ... }]                 -> [Criterion(lambda)]
      #   [:concise, ->(t) { ... }]       -> [Criterion(:concise, lambda)]
      #   [:friendly, :helpful]           -> [Criterion(:friendly), Criterion(:helpful)]
      #   [:friendly, "Short", ->(t) {}]  -> [Criterion(:friendly), Criterion("Short"), Criterion(lambda)]
      #
      # @param args [Array] Mixed criterion arguments
      # @return [Array<Criterion>]
      def self.parse(*args)
        args = args.flatten
        criteria = []
        i = 0

        while i < args.length
          current = args[i]
          next_item = args[i + 1]

          if current.is_a?(Symbol) && next_item.is_a?(Proc)
            # Named lambda: [:concise, ->(turn) { ... }]
            criteria << from(current, next_item)
            i += 2
          elsif current.is_a?(Criterion)
            criteria << current
            i += 1
          else
            # Single argument: Symbol, String, Proc, or CriterionDefinition
            criteria << from(current)
            i += 1
          end
        end

        criteria
      end

      def initialize(name, evaluatable)
        @name = name
        @evaluatable = evaluatable
      end

      # Check if this is a named criterion (Symbol reference to registry)
      # @return [Boolean]
      def named?
        @evaluatable.is_a?(Symbol)
      end

      # Check if this is an adhoc criterion (String description)
      # @return [Boolean]
      def adhoc?
        @evaluatable.is_a?(String)
      end

      # Check if this is a lambda criterion (Proc)
      # @return [Boolean]
      def lambda?
        @evaluatable.is_a?(Proc)
      end

      # Check if this is a CriterionDefinition
      # @return [Boolean]
      def definition?
        @evaluatable.is_a?(DSL::CriterionDefinition)
      end

      # Evaluate the criterion
      #
      # @param turn [Turn] The turn to evaluate
      # @param judge [Judge, nil] Judge for LLM-based evaluation
      # @param conversation [Conversation, nil] Full conversation context
      # @param criteria_registry [Hash, nil] Registry of named criteria
      # @return [Hash] { satisfied: Boolean, reasoning: String }
      def evaluate(turn:, judge: nil, conversation: nil, criteria_registry: {})
        case @evaluatable
        when Proc
          evaluate_lambda(turn)
        when Symbol
          evaluate_named(turn, judge, conversation, criteria_registry)
        when String
          evaluate_adhoc(turn, judge, conversation)
        when DSL::CriterionDefinition
          evaluate_definition(@evaluatable, turn, judge, conversation)
        else
          { satisfied: false, reasoning: "Unknown criterion type: #{@evaluatable.class}" }
        end
      end

      # Get the display name for this criterion
      # @return [String]
      def display_name
        @name
      end

      def to_s
        "Criterion(#{@name})"
      end

      def inspect
        "#<Criterion name=#{@name.inspect} type=#{type}>"
      end

      # Get the type of this criterion
      # @return [Symbol] :named, :adhoc, :lambda, or :definition
      def type
        case @evaluatable
        when Symbol then :named
        when String then :adhoc
        when Proc then :lambda
        when DSL::CriterionDefinition then :definition
        else :unknown
        end
      end

      private

      def evaluate_lambda(turn)
        result = @evaluatable.call(turn)
        { satisfied: !!result, reasoning: result ? "Lambda passed" : "Lambda failed" }
      rescue => e
        { satisfied: false, reasoning: "Lambda error: #{e.message}" }
      end

      def evaluate_named(turn, judge, conversation, criteria_registry)
        unless judge
          return { satisfied: false, reasoning: "No judge configured for criterion evaluation" }
        end

        definition = criteria_registry[@evaluatable]
        unless definition
          return { satisfied: false, reasoning: "Unknown criterion: #{@evaluatable}" }
        end

        evaluate_definition(definition, turn, judge, conversation)
      end

      def evaluate_adhoc(turn, judge, conversation)
        unless judge
          return { satisfied: false, reasoning: "No judge configured for criterion evaluation" }
        end

        # Create temporary CriterionDefinition for adhoc evaluation
        adhoc_def = DSL::CriterionDefinition.new(:adhoc, description: @evaluatable)
        judge.evaluate_criterion(adhoc_def, [turn], conversation)
      end

      def evaluate_definition(definition, turn, judge, conversation)
        if definition.code_based?
          evaluate_code_based_definition(definition, turn, conversation)
        else
          unless judge
            return { satisfied: false, reasoning: "No judge configured for criterion evaluation" }
          end
          judge.evaluate_criterion(definition, [turn], conversation)
        end
      end

      def evaluate_code_based_definition(definition, turn, conversation)
        if definition.match_block
          passed = definition.match_block.call(conversation)
          {
            satisfied: !!passed,
            reasoning: passed ? "Code-based criterion passed" : "Code-based criterion failed"
          }
        elsif definition.match_messages_block
          messages = conversation&.messages || []
          passed = definition.match_messages_block.call(messages)
          {
            satisfied: !!passed,
            reasoning: passed ? "Code-based criterion passed" : "Code-based criterion failed"
          }
        else
          { satisfied: false, reasoning: "No evaluation block defined" }
        end
      rescue => e
        { satisfied: false, reasoning: "Code evaluation error: #{e.message}" }
      end
    end
  end
end
