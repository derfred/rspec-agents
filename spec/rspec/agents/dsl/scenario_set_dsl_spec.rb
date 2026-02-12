require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::DSL::ScenarioSetDSL, type: :agent do
  # Store generated examples for verification
  let(:generated_examples) { [] }

  describe "#scenario_set" do
    context "with valid JSON file" do
      it "loads scenarios from file" do
        scenarios_loaded = nil

        RSpec.describe "Test", type: :agent do
          scenario_set "test", from: "spec/fixtures/scenarios/test_scenarios.json" do |scenario|
            scenarios_loaded ||= []
            scenarios_loaded << scenario
          end
        end

        expect(scenarios_loaded).not_to be_nil
        expect(scenarios_loaded.size).to eq(3)
      end

      it "provides scenario data to block" do
        scenario_names = []

        RSpec.describe "Test", type: :agent do
          scenario_set "test", from: "spec/fixtures/scenarios/test_scenarios.json" do |scenario|
            scenario_names << scenario[:name]

            it "receives scenario #{scenario[:name]}" do
              expect(scenario).to be_a(RSpec::Agents::Scenario)
            end
          end
        end

        expect(scenario_names).to contain_exactly(
          "Simple greeting exchange",
          "Detailed information request",
          "Urgent request handling"
        )
      end

      it "generates separate test examples for each scenario" do
        example_count = 0

        test_group = RSpec.describe "Test", type: :agent do
          scenario_set "test", from: "spec/fixtures/scenarios/test_scenarios.json" do |scenario|
            it "handles #{scenario.name}" do
              example_count += 1
              expect(scenario).to be_a(RSpec::Agents::Scenario)
            end
          end
        end

        # Run the examples
        test_group.run(RSpec.configuration.reporter)

        expect(example_count).to eq(3)
      end
    end

    context "with scenario data access" do
      it "allows accessing scenario via bracket notation" do
        test_group = RSpec.describe "Test", type: :agent do
          scenario_set "test", from: "spec/fixtures/scenarios/test_scenarios.json" do |scenario|
            it "accesses #{scenario[:name]} via brackets" do
              expect(scenario[:id]).not_to be_nil
              expect(scenario[:goal]).not_to be_nil
              expect(scenario[:context]).to be_an(Array)
            end
          end
        end

        result = test_group.run(RSpec.configuration.reporter)
        expect(result).to be true
      end

      it "allows accessing scenario via dot notation" do
        test_group = RSpec.describe "Test", type: :agent do
          scenario_set "test", from: "spec/fixtures/scenarios/test_scenarios.json" do |scenario|
            it "accesses #{scenario.name} via dot notation" do
              expect(scenario.id).not_to be_nil
              expect(scenario.goal).not_to be_nil
              expect(scenario.context).to be_an(Array)
              expect(scenario.personality).to be_a(String)
            end
          end
        end

        result = test_group.run(RSpec.configuration.reporter)
        expect(result).to be true
      end
    end

    context "with scenario metadata" do
      it "stores scenarios at class level" do
        test_group = RSpec.describe "Test", type: :agent do
          scenario_set "my_scenarios", from: "spec/fixtures/scenarios/test_scenarios.json" do |scenario|
            it "test #{scenario.name}" do
              # Empty test
            end
          end
        end

        expect(test_group.scenarios).to have_key("my_scenarios")
        expect(test_group.scenarios["my_scenarios"]).to be_an(Array)
        expect(test_group.scenarios["my_scenarios"].size).to eq(3)
      end

      it "allows multiple scenario sets in same describe block" do
        # Create a second fixture file
        second_fixture = [
          { "id" => "extra1", "name" => "Extra 1", "goal" => "Extra goal" }
        ].to_json
        extra_file_path = "spec/fixtures/scenarios/extra_scenarios.json"
        FileUtils.mkdir_p(File.dirname(extra_file_path))
        File.write(extra_file_path, second_fixture)

        test_group = RSpec.describe "Test", type: :agent do
          scenario_set "set1", from: "spec/fixtures/scenarios/test_scenarios.json" do |scenario|
            it "handles #{scenario.name}" do
              # Empty test
            end
          end

          scenario_set "set2", from: "spec/fixtures/scenarios/extra_scenarios.json" do |scenario|
            it "handles #{scenario.name}" do
              # Empty test
            end
          end
        end

        expect(test_group.scenarios.keys).to contain_exactly("set1", "set2")
        expect(test_group.scenarios["set1"].size).to eq(3)
        expect(test_group.scenarios["set2"].size).to eq(1)

        FileUtils.rm_f(extra_file_path)
      end
    end

    context "with file path resolution" do
      it "resolves paths relative to spec file" do
        # This test verifies that the file is found when using a relative path
        test_group = RSpec.describe "Test", type: :agent do
          scenario_set "test", from: "spec/fixtures/scenarios/test_scenarios.json" do |scenario|
            it "test" do
              expect(scenario).to be_a(RSpec::Agents::Scenario)
            end
          end
        end

        result = test_group.run(RSpec.configuration.reporter)
        expect(result).to be true
      end
    end

    context "with error handling" do
      it "raises error for non-existent file" do
        expect {
          RSpec.describe "Test", type: :agent do
            scenario_set "test", from: "nonexistent_scenarios.json" do |scenario|
              it "test" do
                # Empty
              end
            end
          end
        }.to raise_error(RSpec::Core::ExampleGroup::WrongScopeError, /not found/)
      end

      it "raises error for invalid JSON" do
        invalid_file = "spec/fixtures/scenarios/invalid.json"
        FileUtils.mkdir_p(File.dirname(invalid_file))
        File.write(invalid_file, "{ invalid json }")

        expect {
          RSpec.describe "Test", type: :agent do
            scenario_set "test", from: "spec/fixtures/scenarios/invalid.json" do |scenario|
              it "test" do
                # Empty
              end
            end
          end
        }.to raise_error(RSpec::Core::ExampleGroup::WrongScopeError, /Invalid JSON/)

        FileUtils.rm_f(invalid_file)
      end

      it "raises error for missing required fields" do
        incomplete_file = "spec/fixtures/scenarios/incomplete.json"
        FileUtils.mkdir_p(File.dirname(incomplete_file))
        File.write(incomplete_file, '[{"name": "Test"}]')

        expect {
          RSpec.describe "Test", type: :agent do
            scenario_set "test", from: "spec/fixtures/scenarios/incomplete.json" do |scenario|
              it "test" do
                # Empty
              end
            end
          end
        }.to raise_error(RSpec::Core::ExampleGroup::WrongScopeError, /missing required fields/)

        FileUtils.rm_f(incomplete_file)
      end
    end
  end

  describe "#scenario" do
    it "provides access to current scenario within test" do
      test_group = RSpec.describe "Test", type: :agent do
        scenario_set "test", from: "spec/fixtures/scenarios/test_scenarios.json" do |s|
          it "accesses scenario via helper" do
            expect(scenario).to be_a(RSpec::Agents::Scenario)
            expect(scenario.id).to eq(s.id)
            expect(scenario.name).to eq(s.name)
          end
        end
      end

      result = test_group.run(RSpec.configuration.reporter)
      expect(result).to be true
    end

    it "returns nil when not in scenario-based test" do
      test_group = RSpec.describe "Test", type: :agent do
        it "has no scenario" do
          expect(scenario).to be_nil
        end
      end

      result = test_group.run(RSpec.configuration.reporter)
      expect(result).to be true
    end
  end
end
