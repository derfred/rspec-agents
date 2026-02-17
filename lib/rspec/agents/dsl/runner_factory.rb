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

        # Get the shared turn executor from the test context
        # @return [TurnExecutor]
        def turn_executor
          @context.turn_executor
        end

        # Build an agent proxy for assertions
        # @return [AgentProxy]
        def build_agent_proxy
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
            turn_executor:    turn_executor,
            llm:              llm,
            judge:            @context.build_judge(llm),
            graph:            @context.topic_graph,
            simulator_config: simulator_config,
            event_bus:        @context.event_bus
          )
        end
      end
    end
  end
end
