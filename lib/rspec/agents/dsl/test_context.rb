module RSpec
  module Agents
    module DSL
      # Factory that enables the super() syntax in agent blocks.
      # Creates a dynamic class where calling super(...) delegates to the global adapter.
      #
      # Usage in test files:
      #   agent { super(shop: shop, person: person) }
      #
      # This works by:
      # 1. Creating a base class with a `call` method that builds via the global adapter
      # 2. Creating a subclass that defines `call` using define_method with the user's block
      # 3. When the block calls super(...), Ruby routes it to the base class's call method
      module AgentBuilderFactory
        def self.build(adapter_class, base_context, rspec_instance, &block)
          # Create a base class that provides the super implementation
          base_klass = Class.new do
            def initialize(adapter_class, base_context, rspec_instance)
              @adapter_class = adapter_class
              @base_context = base_context
              @rspec_instance = rspec_instance
            end

            # This is what super(...) calls - merges context and builds the agent
            def call(**additional_context)
              merged_context = @base_context.merge(additional_context)

              case @adapter_class
              when Class
                @adapter_class.build(merged_context)
              when Proc
                @adapter_class.call(merged_context)
              else
                @adapter_class
              end
            end

            # Forward method calls to the RSpec example instance
            # This allows access to let variables like shop, person, etc.
            def method_missing(method_name, *args, &blk)
              if @rspec_instance&.respond_to?(method_name)
                @rspec_instance.send(method_name, *args, &blk)
              else
                raise NoMethodError, "undefined method `#{method_name}' for #{self.class}"
              end
            end

            def respond_to_missing?(method_name, include_private = false)
              @rspec_instance&.respond_to?(method_name) || false
            end
          end

          # Create a subclass that overrides call with the user's block
          # Using define_method preserves the super chain
          sub_klass = Class.new(base_klass)
          sub_klass.define_method(:call, &block)

          # Instantiate and invoke
          builder = sub_klass.new(adapter_class, base_context, rspec_instance)
          builder.call
        end
      end

      # Centralized context object that holds all test state
      # Replaces scattered instance variables with a single source of truth
      class TestContext
        attr_reader :topics, :criteria, :simulator_config, :event_bus, :scenario,
                    :stable_example_id
        attr_accessor :conversation, :topic_graph

        # @param test_class [Class] The RSpec example group class
        # @param rspec_example [RSpec::Core::Example, nil] Current RSpec example
        # @param rspec_example_instance [Object, nil] The RSpec example instance (provides access to let variables)
        # @param scenario [Scenario, nil] Current scenario if running scenario-based test
        def initialize(test_class:, rspec_example: nil, rspec_example_instance: nil, scenario: nil)
          @test_class              = test_class
          @rspec_example           = rspec_example
          @rspec_example_instance  = rspec_example_instance
          @scenario                = scenario
          @stable_example_id       = build_stable_example_id
          @topics           = collect_inherited(:shared_topics)
          @criteria         = collect_inherited(:criteria)
          @simulator_config = build_simulator_config
          @topic_graph      = nil
          # Use thread-local event bus if available (set by HeadlessRunner in parallel mode)
          # Otherwise use the singleton EventBus
          @event_bus    = Thread.current[:rspec_agents_event_bus] || EventBus.instance
          @conversation = Conversation.new(event_bus: @event_bus)
        end

        # Build agent instance from configuration hierarchy
        # @return [Agents::Base]
        def build_agent
          agent_config = find_inherited(:agent_override)
          context_hash = build_rspec_context

          resolve_config(agent_config || RSpec::Agents.configuration.agent, context_hash)
        end

        # Build LLM instance from global configuration
        # @return [Llm::Base]
        def build_llm
          RSpec::Agents.configuration.llm || Llm::Mock.new
        end

        # Build judge instance with accumulated criteria
        # @param llm [Llm::Base]
        # @return [Judge]
        def build_judge(llm)
          Judge.new(llm: llm, criteria: @criteria)
        end

        # Merge additional simulator config (from test-level block)
        # @param override [SimulatorConfig]
        # @return [SimulatorConfig]
        def merge_simulator_config(override)
          @simulator_config.merge(override)
        end

        private

        # Collect values from inheritance chain and merge them
        # Child values override parent values (later in chain wins)
        # @param method_name [Symbol]
        # @return [Hash]
        def collect_inherited(method_name)
          ancestors_with_method(method_name).reduce({}) do |result, klass|
            klass.send(method_name).merge(result)
          end
        end

        # Find first non-nil value walking up the inheritance chain
        # @param method_name [Symbol]
        # @return [Object, nil]
        def find_inherited(method_name)
          ancestors_with_method(method_name).each do |klass|
            value = klass.send(method_name)
            return value if value
          end
          nil
        end

        # Get ancestors that respond to a given method
        # Stops at Object (doesn't include BasicObject or Kernel)
        # @param method_name [Symbol]
        # @return [Array<Class>]
        def ancestors_with_method(method_name)
          @test_class.ancestors
            .take_while { |k| k != Object }
            .select { |k| k.respond_to?(method_name) }
        end

        # Build effective simulator config by merging all configs from inheritance chain
        # Ancestors are processed first, so child configs override parent configs
        # @return [SimulatorConfig]
        def build_simulator_config
          configs = ancestors_with_method(:simulator_configs)
            .reverse  # Process ancestors first (outermost describe blocks)
            .flat_map { |k| k.simulator_configs }

          return SimulatorConfig.new if configs.empty?
          configs.reduce(SimulatorConfig.new) { |merged, config| merged.merge(config) }
        end

        # Resolve agent configuration to an agent instance
        # @param config [Class, Proc, Object]
        # @param context_hash [Hash]
        # @return [Agents::Base]
        def resolve_config(config, context_hash)
          case config
          when Class then config.build(context_hash)
          when Proc
            # Check block arity to determine syntax:
            # - arity == 1: block expects |context| argument (traditional syntax)
            # - arity == 0 or -1: block uses super() syntax
            if config.arity == 1
              # Traditional syntax: agent { |context| ... }
              if @rspec_example_instance
                @rspec_example_instance.instance_exec(context_hash, &config)
              else
                config.call(context_hash)
              end
            else
              # super() syntax: agent { super(shop: shop) }
              # Use factory to create a class where super() works
              global_adapter = RSpec::Agents.configuration.agent
              AgentBuilderFactory.build(global_adapter, context_hash, @rspec_example_instance, &config)
            end
          else config
          end
        end

        # Build context hash from current RSpec example metadata
        # @return [Hash]
        def build_rspec_context
          context = {}

          if @rspec_example
            context.merge!(
              test_name: @rspec_example.full_description,
              test_file: @rspec_example.file_path,
              test_line: @rspec_example.location&.split(":")&.last&.to_i,
              tags:      (@rspec_example.metadata.slice(:focus, :slow, :skip) rescue {})
            )
          end

          # Include scenario data if present
          context[:scenario] = @scenario if @scenario

          context
        end

        # Build stable example ID for cross-experiment comparison
        # @return [StableExampleId, nil]
        def build_stable_example_id
          return nil unless @rspec_example

          StableExampleId.generate(@rspec_example, scenario: @scenario)
        end
      end
    end
  end
end
