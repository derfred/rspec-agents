module RSpec
  module Agents
    module DSL
      # Proxy for user interactions in scripted tests
      # Provides clean API for sending messages and running simulations
      class UserProxy
        # @param context [TestContext]
        # @param turn_executor [TurnExecutor]
        # @param runner_factory [RunnerFactory]
        def initialize(context:, turn_executor:, runner_factory:)
          @context = context
          @turn_executor = turn_executor
          @runner_factory = runner_factory
        end

        # Send a user message and get agent response
        # @param text [String]
        # @param metadata [Hash]
        # @return [AgentResponse]
        def says(text, metadata: {})
          @turn_executor.execute(text, source: :script, metadata: metadata)
        end

        # Run a simulated conversation with LLM-generated user messages
        # @yield Optional block to configure simulation (adds goal, overrides, etc.)
        # @return [Runners::SimulationResults]
        def simulate(&block)
          config = prepare_simulator_config(&block)
          validate_simulation_prerequisites!(config)

          simulator = @runner_factory.build_user_simulator(config)
          simulator.run
          results = simulator.simulation_results

          raise_if_failed!(results)
          results
        end

        private

        # Prepare simulator config, merging any test-level overrides
        # @return [SimulatorConfig]
        def prepare_simulator_config(&block)
          return @context.simulator_config unless block_given?

          override = SimulatorConfig.new
          override.instance_eval(&block)
          @context.merge_simulator_config(override)
        end

        # Validate that simulation can run
        # @param config [SimulatorConfig]
        # @raise [ArgumentError] if goal is missing
        # @raise [RuntimeError] if topic graph is missing
        def validate_simulation_prerequisites!(config)
          raise ArgumentError, "user.simulate requires a goal" unless config.goal
          raise "No topic graph defined. Call expect_conversation_to before user.simulate" unless @context.topic_graph
        end

        # Raise RSpec expectation error if simulation failed
        # @param results [Runners::SimulationResults]
        def raise_if_failed!(results)
          return if results.passed?

          failures = results.failure_messages.join("\n")
          raise RSpec::Expectations::ExpectationNotMetError, "Simulation failed:\n#{failures}"
        end
      end
    end
  end
end
