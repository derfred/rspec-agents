module RSpec
  module Agents
    module DSL
      # Factory for creating runner instances with proper dependencies
      # Encapsulates the complexity of wiring up runners with their dependencies
      class RunnerFactory
        # @param context [TestContext]
        def initialize(context)
          @context = context
        end

        # Build a turn executor for step-by-step test conversations
        # @return [TurnExecutor]
        def build_turn_executor
          TurnExecutor.new(
            agent:        @context.build_agent,
            conversation: @context.conversation,
            graph:        @context.topic_graph,
            judge:        @context.build_judge(@context.build_llm),
            event_bus:    @context.event_bus
          )
        end

        # Build an agent proxy for assertions
        # @param turn_executor [TurnExecutor]
        # @return [AgentProxy]
        def build_agent_proxy(turn_executor)
          AgentProxy.new(
            turn_executor: turn_executor,
            judge:         @context.build_judge(@context.build_llm)
          )
        end

        # Build a user simulator for LLM-driven conversations
        # @param simulator_config [SimulatorConfig]
        # @return [Runners::UserSimulator]
        def build_user_simulator(simulator_config)
          llm = @context.build_llm
          Runners::UserSimulator.new(
            agent:            @context.build_agent,
            llm:              llm,
            judge:            @context.build_judge(llm),
            graph:            @context.topic_graph,
            simulator_config: simulator_config,
            event_bus:        @context.event_bus,
            conversation:     @context.conversation
          )
        end
      end
    end
  end
end
