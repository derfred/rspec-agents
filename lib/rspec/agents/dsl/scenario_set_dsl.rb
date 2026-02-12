require_relative "../scenario_loader"

module RSpec
  module Agents
    module DSL
      # DSL module for scenario-driven testing
      # Provides the `scenario_set` directive for loading test variations from external data sources
      #
      # @example Basic usage
      #   RSpec.describe "Agent" do
      #     scenario_set "venues", from: "scenarios/venues.json" do |scenario|
      #       it "handles #{scenario.name}" do
      #         user.simulate do
      #           goal scenario.goal
      #           personality scenario.personality if scenario.personality
      #         end
      #       end
      #     end
      #   end
      #
      module ScenarioSetDSL
        def self.included(base)
          base.extend(ClassMethods)
          base.include(TestContextAccess)
        end

        module ClassMethods
          # Define a set of scenarios loaded from an external data source or inline array
          # Generates one RSpec example per scenario
          #
          # @param name [String] Name of the scenario set (for documentation)
          # @param from [String, nil] Path to scenario data file (JSON) - optional if scenarios provided
          # @param scenarios [Array<Hash>, nil] Inline array of scenario hashes - optional if from provided
          # @yield [scenario] Block that defines the test for each scenario
          # @yieldparam scenario [Scenario] Scenario data
          #
          # @example From JSON file
          #   scenario_set "venue_searches", from: "scenarios/venues.json" do |scenario|
          #     it "handles #{scenario.name}" do
          #       user.simulate do
          #         goal scenario.goal
          #       end
          #     end
          #   end
          #
          # @example From inline array
          #   scenario_set "event_types", scenarios: [
          #     { id: "conference", name: "Conference", goal: "Organize a conference" },
          #     { id: "workshop", name: "Workshop", goal: "Plan a workshop" }
          #   ] do |scenario|
          #     it "handles #{scenario.name}" do
          #       user.simulate do
          #         goal scenario.goal
          #       end
          #     end
          #   end
          def scenario_set(name, from: nil, scenarios: nil, &block)
            # Validate arguments - must provide either from: or scenarios:, but not both
            if from.nil? && scenarios.nil?
              raise RSpec::Core::ExampleGroup::WrongScopeError,
                "scenario_set '#{name}' requires either `from:` (file path) or `scenarios:` (array)"
            end

            if from && scenarios
              raise RSpec::Core::ExampleGroup::WrongScopeError,
                "scenario_set '#{name}' accepts either `from:` or `scenarios:`, not both"
            end

            # Load scenarios from file or inline array
            loaded_scenarios = if scenarios
                                 load_from_array(name, scenarios)
                               else
                                 load_from_file(name, from)
                               end

            # Store scenarios for potential aggregation use
            self.scenarios[name] = loaded_scenarios

            # Generate RSpec examples for each scenario
            loaded_scenarios.each do |scenario|
              # Capture scenario in closure
              captured_scenario = scenario

              # Create a wrapper that injects the scenario via metadata
              wrapped_block = proc do |*args|
                # Call the original block which should create an `it` example
                # We'll wrap it to inject scenario metadata
                original_it = method(:it)

                # Override `it` temporarily to inject scenario
                define_singleton_method(:it) do |description = nil, *test_args, **metadata, &test_block|
                  # Add scenario to metadata
                  metadata[:rspec_agents_scenario] = captured_scenario

                  # Create a wrapped test block that sets the instance variable
                  wrapped_test_block = proc do
                    @rspec_agents_current_scenario = captured_scenario
                    instance_eval(&test_block)
                  end

                  # Call original it with wrapped block
                  original_it.call(description, *test_args, **metadata, &wrapped_test_block)
                end

                # Call user's block
                block.call(captured_scenario, *args)

                # Restore original it method
                define_singleton_method(:it, original_it)
              end

              # Execute the wrapped block
              instance_eval(&wrapped_block)
            end
          end

          # Access all defined scenario sets
          # @return [Hash<String, Array<Scenario>>] Map of scenario set names to scenarios
          def scenarios
            @scenarios ||= {}
          end

          private

          # Load scenarios from a JSON file
          # @param name [String] Scenario set name (for error messages)
          # @param file_path [String] Path to JSON file
          # @return [Array<Scenario>] Loaded scenarios
          def load_from_file(name, file_path)
            base_path = if defined?(Rails) && Rails.respond_to?(:root)
                          Rails.root.to_s
                        elsif File.absolute_path?(file_path)
                          nil
                        else
                          Dir.pwd
                        end

            begin
              ScenarioLoader.load(file_path, base_path: base_path)
            rescue ScenarioLoader::LoadError, ScenarioLoader::ValidationError => e
              raise RSpec::Core::ExampleGroup::WrongScopeError, "Error loading scenarios for '#{name}': #{e.message}"
            end
          end

          # Load scenarios from an inline array
          # @param name [String] Scenario set name (for error messages)
          # @param scenarios_array [Array<Hash>] Array of scenario hashes
          # @return [Array<Scenario>] Loaded scenarios
          def load_from_array(name, scenarios_array)
            begin
              ScenarioLoader.load_from_array(scenarios_array)
            rescue ScenarioLoader::ValidationError => e
              raise RSpec::Core::ExampleGroup::WrongScopeError, "Error loading scenarios for '#{name}': #{e.message}"
            end
          end
        end

        # Access the current scenario from within a test
        # @return [Scenario, nil] Current scenario if running in a scenario-based test
        def scenario
          rspec_agents_test_context.scenario
        end
      end
    end
  end
end
