module RSpec
  module Agents
    module DSL
      # Criterion definition with optional examples for LLM-based evaluation
      class CriterionDefinition
        attr_reader :name, :good_examples, :bad_examples, :edge_cases
        attr_reader :match_block, :match_messages_block

        # @param name [Symbol, String]
        # @param description [String, nil]
        # @yield Optional block for complex definition
        def initialize(name, description: nil, &block)
          @name = name.to_sym
          @description = description
          @good_examples = []
          @bad_examples = []
          @edge_cases = []
          @match_block = nil
          @match_messages_block = nil
          instance_eval(&block) if block_given?
        end

        # Get or set description
        # @param text [String, nil]
        # @return [String, nil]
        def description(text = nil)
          text.nil? ? @description : (@description = text)
        end

        # Add a good example
        # @param text [String]
        # @param explanation [String]
        def good_example(text, explanation:)
          @good_examples << { text: text, explanation: explanation }
        end

        # Add a bad example
        # @param text [String]
        # @param explanation [String]
        def bad_example(text, explanation:)
          @bad_examples << { text: text, explanation: explanation }
        end

        # Add an edge case
        # @param text [String]
        # @param verdict [Boolean]
        # @param explanation [String]
        def edge_case(text, verdict:, explanation:)
          @edge_cases << { text: text, verdict: verdict, explanation: explanation }
        end

        # Set code-based evaluation block
        # @yield [conversation]
        def match(&block)
          @match_block = block
        end

        # Set message-based evaluation block
        # @yield [messages]
        def match_messages(&block)
          @match_messages_block = block
        end

        # Check if this criterion uses code-based evaluation
        # @return [Boolean]
        def code_based?
          !!(@match_block || @match_messages_block)
        end

        # Check if this criterion has examples
        # @return [Boolean]
        def has_examples?
          @good_examples.any? || @bad_examples.any? || @edge_cases.any?
        end
      end
    end
  end
end
