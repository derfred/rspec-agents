module RSpec
  module Agents
    # Configuration for the user simulator
    # Supports inheritance through RSpec nesting with specific merge behaviors
    #
    # Inheritance rules (per design doc Section 3.4):
    # - String replaces block, block replaces string
    # - Block + block = notes merged
    # - Rules are always accumulated
    # - max_turns/stop_when replaced by child
    # - goal/template are test-level only (not inheritable)
    class SimulatorConfig
      attr_reader :role_value, :personality_value, :context_value
      attr_reader :rules, :max_turns, :stop_when, :goal, :template
      attr_reader :topic_overrides

      def initialize
        @role_value = nil
        @role_type = nil  # :string or :block

        @personality_value = nil
        @personality_type = nil
        @personality_notes = []

        @context_value = nil
        @context_type = nil
        @context_notes = []

        @rules = []
        @max_turns = nil
        @stop_when = nil
        @goal = nil
        @template = nil
        @topic_overrides = {}

        @current_notes_target = nil  # Tracks which block we're in
      end

      # DSL: Set the user's role
      # @param text [String, nil] Role description (or nil to use block)
      # @yield Block for complex role definition (not implemented yet)
      def role(text = nil, &block)
        if block_given?
          @role_type = :block
          @role_value = block
        else
          @role_type = :string
          @role_value = text
        end
      end

      # DSL: Set the user's personality
      # @param text [String, nil] Personality description (or nil to use block)
      # @yield Block for personality with notes
      def personality(text = nil, &block)
        if block_given?
          @personality_type = :block
          @personality_value = nil
          @current_notes_target = :personality
          instance_eval(&block)
          @current_notes_target = nil
        else
          @personality_type = :string
          @personality_value = text
          @personality_notes = []
        end
      end

      # DSL: Set the context
      # @param text [String, nil] Context description (or nil to use block)
      # @yield Block for context with notes
      def context(text = nil, &block)
        if block_given?
          @context_type = :block
          @context_value = nil
          @current_notes_target = :context
          instance_eval(&block)
          @current_notes_target = nil
        else
          @context_type = :string
          @context_value = text
          @context_notes = []
        end
      end

      # DSL: Add a note (used within personality/context blocks)
      # @param text [String] Note text
      def note(text)
        case @current_notes_target
        when :personality
          @personality_notes << text
        when :context
          @context_notes << text
        else
          # Default to personality notes if called outside a block
          @personality_notes << text
        end
      end

      # DSL: Add a rule
      # @param type [Symbol, Proc] :should, :should_not, or a lambda for dynamic rules
      # @param text [String, nil] Rule description (for :should/:should_not)
      # @yield Optional block for dynamic rules
      def rule(type_or_lambda = nil, text = nil, &block)
        if block_given?
          @rules << { type: :dynamic, block: block }
        elsif type_or_lambda.is_a?(Proc)
          @rules << { type: :dynamic, block: type_or_lambda }
        elsif type_or_lambda.is_a?(Symbol) && text
          @rules << { type: type_or_lambda, text: text }
        end
      end

      # DSL: Set maximum turns
      # @param count [Integer]
      attr_writer :max_turns

      # For DSL compatibility
      def max_turns(count = nil)
        if count.nil?
          @max_turns
        else
          @max_turns = count
        end
      end

      # DSL: Set stop condition
      # @yield [turn, conversation] Block returning true to stop
      def stop_when(&block)
        if block_given?
          @stop_when = block
        else
          @stop_when
        end
      end

      # DSL: Set the goal (test-level only)
      # @param text [String]
      def goal(text = nil)
        if text.nil?
          @goal
        else
          @goal = text
        end
      end

      # DSL: Set the template path (test-level only)
      # @param path [String, nil] Path to ERB template file
      def template(path = nil)
        if path.nil?
          @template
        else
          @template = path.to_s
        end
      end

      # DSL: Override settings during a specific topic
      # @param topic_name [Symbol] Topic name
      # @yield Block with overrides
      def during_topic(topic_name, &block)
        override = self.class.new
        override.instance_eval(&block)
        @topic_overrides[topic_name.to_sym] = override
      end

      # Get the effective role as an array
      # @return [Array<String>] Role items (empty array if not set)
      def effective_role
        case @role_type
        when :string
          [@role_value]
        when :block
          result = @role_value&.call
          result ? [result] : []
        else
          []
        end
      end

      # Get the effective personality as an array
      # @return [Array<String>] Personality items (empty array if not set)
      def effective_personality
        case @personality_type
        when :string
          [@personality_value]
        when :block
          @personality_notes.dup
        else
          []
        end
      end

      # Get the effective context as an array
      # @return [Array<String>] Context items (empty array if not set)
      def effective_context
        case @context_type
        when :string
          [@context_value]
        when :block
          @context_notes.dup
        else
          []
        end
      end

      # Merge with a child config using inheritance rules
      # @param child [SimulatorConfig] Child configuration
      # @return [SimulatorConfig] New merged configuration
      def merge(child)
        result = self.class.new

        # Role: String/block replacement rules
        merge_setting(result, :role, child)

        # Personality: String/block replacement, block+block = merge notes
        merge_personality(result, child)

        # Context: String/block replacement, block+block = merge notes
        merge_context(result, child)

        # Rules: Always accumulated
        result.instance_variable_set(:@rules, @rules + child.rules)

        # max_turns: Child replaces parent
        result.instance_variable_set(:@max_turns, child.max_turns || @max_turns)

        # stop_when: Child replaces parent
        result.instance_variable_set(:@stop_when, child.instance_variable_get(:@stop_when) || @stop_when)

        # goal: Test-level only, child takes precedence
        result.instance_variable_set(:@goal, child.instance_variable_get(:@goal) || @goal)

        # template: Test-level only, child takes precedence
        result.instance_variable_set(:@template, child.template || @template)

        # Topic overrides: Merge hashes
        merged_overrides = @topic_overrides.merge(child.topic_overrides)
        result.instance_variable_set(:@topic_overrides, merged_overrides)

        result
      end

      # Get config with topic-specific overrides applied
      # @param topic_name [Symbol] Current topic
      # @return [SimulatorConfig]
      def for_topic(topic_name)
        override = @topic_overrides[topic_name.to_sym]
        override ? merge(override) : self
      end

      def to_h
        {
          role:        effective_role,
          personality: effective_personality,
          context:     effective_context,
          rules:       rules,
          max_turns:   @max_turns,
          goal:        @goal
        }
      end

      private

      def merge_setting(result, name, child)
        parent_type = instance_variable_get(:"@#{name}_type")
        parent_value = instance_variable_get(:"@#{name}_value")
        child_type = child.instance_variable_get(:"@#{name}_type")
        child_value = child.instance_variable_get(:"@#{name}_value")

        if child_type
          # Child has a value - it replaces parent
          result.instance_variable_set(:"@#{name}_type", child_type)
          result.instance_variable_set(:"@#{name}_value", child_value)
        else
          # No child value - inherit from parent
          result.instance_variable_set(:"@#{name}_type", parent_type)
          result.instance_variable_set(:"@#{name}_value", parent_value)
        end
      end

      def merge_personality(result, child)
        parent_type = @personality_type
        child_type = child.instance_variable_get(:@personality_type)

        if child_type == :string
          # String replaces anything
          result.instance_variable_set(:@personality_type, :string)
          result.instance_variable_set(:@personality_value, child.personality_value)
          result.instance_variable_set(:@personality_notes, [])
        elsif child_type == :block && parent_type == :block
          # Block + Block = merge notes
          result.instance_variable_set(:@personality_type, :block)
          result.instance_variable_set(:@personality_value, nil)
          result.instance_variable_set(:@personality_notes, @personality_notes + child.instance_variable_get(:@personality_notes))
        elsif child_type == :block
          # Block replaces string
          result.instance_variable_set(:@personality_type, :block)
          result.instance_variable_set(:@personality_value, nil)
          result.instance_variable_set(:@personality_notes, child.instance_variable_get(:@personality_notes))
        else
          # Inherit from parent
          result.instance_variable_set(:@personality_type, parent_type)
          result.instance_variable_set(:@personality_value, @personality_value)
          result.instance_variable_set(:@personality_notes, @personality_notes.dup)
        end
      end

      def merge_context(result, child)
        parent_type = @context_type
        child_type = child.instance_variable_get(:@context_type)

        if child_type == :string
          # String replaces anything
          result.instance_variable_set(:@context_type, :string)
          result.instance_variable_set(:@context_value, child.context_value)
          result.instance_variable_set(:@context_notes, [])
        elsif child_type == :block && parent_type == :block
          # Block + Block = merge notes
          result.instance_variable_set(:@context_type, :block)
          result.instance_variable_set(:@context_value, nil)
          result.instance_variable_set(:@context_notes, @context_notes + child.instance_variable_get(:@context_notes))
        elsif child_type == :block
          # Block replaces string
          result.instance_variable_set(:@context_type, :block)
          result.instance_variable_set(:@context_value, nil)
          result.instance_variable_set(:@context_notes, child.instance_variable_get(:@context_notes))
        else
          # Inherit from parent
          result.instance_variable_set(:@context_type, parent_type)
          result.instance_variable_set(:@context_value, @context_value)
          result.instance_variable_set(:@context_notes, @context_notes.dup)
        end
      end
    end
  end
end
