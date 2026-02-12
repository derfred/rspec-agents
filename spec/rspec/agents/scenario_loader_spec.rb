require "spec_helper"
require "rspec/agents"
require "tempfile"
require "fileutils"

RSpec.describe RSpec::Agents::ScenarioLoader do
  let(:valid_scenarios_json) do
    [
      {
        "id"          => "scenario1",
        "name"        => "First Scenario",
        "goal"        => "Test goal 1",
        "context"     => ["Context 1"],
        "personality" => "Professional"
      },
      {
        "id"          => "scenario2",
        "name"        => "Second Scenario",
        "goal"        => "Test goal 2",
        "context"     => ["Context 2", "Context 3"],
        "personality" => "Casual"
      }
    ].to_json
  end

  let(:temp_dir) { Dir.mktmpdir }
  let(:json_file_path) { File.join(temp_dir, "scenarios.json") }

  before do
    FileUtils.mkdir_p(temp_dir)
  end

  after do
    FileUtils.rm_rf(temp_dir)
  end

  describe ".load" do
    context "with JSON file" do
      it "loads scenarios from JSON file" do
        File.write(json_file_path, valid_scenarios_json)

        scenarios = described_class.load(json_file_path)

        expect(scenarios).to be_an(Array)
        expect(scenarios.size).to eq(2)
        expect(scenarios.first).to be_a(RSpec::Agents::Scenario)
        expect(scenarios.first[:name]).to eq("First Scenario")
        expect(scenarios.last[:name]).to eq("Second Scenario")
      end

      it "assigns indices to scenarios" do
        File.write(json_file_path, valid_scenarios_json)

        scenarios = described_class.load(json_file_path)

        expect(scenarios[0].index).to eq(0)
        expect(scenarios[1].index).to eq(1)
      end

      it "resolves relative paths from base_path" do
        File.write(json_file_path, valid_scenarios_json)

        scenarios = described_class.load("scenarios.json", base_path: temp_dir)

        expect(scenarios.size).to eq(2)
      end

      it "handles absolute paths" do
        File.write(json_file_path, valid_scenarios_json)

        scenarios = described_class.load(json_file_path)

        expect(scenarios.size).to eq(2)
      end
    end

    context "with unsupported file type" do
      it "raises LoadError" do
        expect {
          described_class.load("scenarios.txt")
        }.to raise_error(RSpec::Agents::ScenarioLoader::LoadError, /Unsupported scenario source/)
      end
    end

    context "with non-existent file" do
      it "raises LoadError" do
        expect {
          described_class.load("/nonexistent/scenarios.json")
        }.to raise_error(RSpec::Agents::ScenarioLoader::LoadError, /Scenario file not found/)
      end
    end
  end

  describe ".load_json" do
    context "with valid JSON" do
      it "parses and returns scenarios" do
        File.write(json_file_path, valid_scenarios_json)

        scenarios = described_class.load_json(json_file_path)

        expect(scenarios).to be_an(Array)
        expect(scenarios.size).to eq(2)
        expect(scenarios.first[:goal]).to eq("Test goal 1")
      end

      it "handles empty array" do
        File.write(json_file_path, "[]")

        scenarios = described_class.load_json(json_file_path)

        expect(scenarios).to eq([])
      end
    end

    context "with invalid JSON" do
      it "raises LoadError for malformed JSON" do
        File.write(json_file_path, "{ invalid json }")

        expect {
          described_class.load_json(json_file_path)
        }.to raise_error(RSpec::Agents::ScenarioLoader::LoadError, /Invalid JSON/)
      end

      it "raises ValidationError for non-array JSON" do
        File.write(json_file_path, '{"key": "value"}')

        expect {
          described_class.load_json(json_file_path)
        }.to raise_error(RSpec::Agents::ScenarioLoader::ValidationError, /must contain a JSON array/)
      end
    end

    context "with file access errors" do
      it "raises LoadError for permission denied" do
        File.write(json_file_path, valid_scenarios_json)
        File.chmod(0000, json_file_path)

        expect {
          described_class.load_json(json_file_path)
        }.to raise_error(RSpec::Agents::ScenarioLoader::LoadError, /Permission denied/)

        File.chmod(0644, json_file_path) # Restore for cleanup
      end
    end
  end

  describe "scenario validation" do
    context "with missing required fields" do
      it "raises ValidationError for missing name" do
        json = [{ "goal" => "Test goal" }].to_json
        File.write(json_file_path, json)

        expect {
          described_class.load_json(json_file_path)
        }.to raise_error(RSpec::Agents::ScenarioLoader::ValidationError, /missing required fields.*name/)
      end

      it "raises ValidationError for missing goal" do
        json = [{ "name" => "Test" }].to_json
        File.write(json_file_path, json)

        expect {
          described_class.load_json(json_file_path)
        }.to raise_error(RSpec::Agents::ScenarioLoader::ValidationError, /missing required fields.*goal/)
      end
    end

    context "with invalid field types" do
      it "raises ValidationError for non-string name" do
        json = [{ "name" => 123, "goal" => "Test goal" }].to_json
        File.write(json_file_path, json)

        expect {
          described_class.load_json(json_file_path)
        }.to raise_error(RSpec::Agents::ScenarioLoader::ValidationError, /field 'name' must be String/)
      end

      it "raises ValidationError for non-string goal" do
        json = [{ "name" => "Test", "goal" => true }].to_json
        File.write(json_file_path, json)

        expect {
          described_class.load_json(json_file_path)
        }.to raise_error(RSpec::Agents::ScenarioLoader::ValidationError, /field 'goal' must be String/)
      end

      it "raises ValidationError for non-array context" do
        json = [{ "name" => "Test", "goal" => "Goal", "context" => "string" }].to_json
        File.write(json_file_path, json)

        expect {
          described_class.load_json(json_file_path)
        }.to raise_error(RSpec::Agents::ScenarioLoader::ValidationError, /field 'context' must be Array/)
      end

      it "raises ValidationError for non-hash verification" do
        json = [{ "name" => "Test", "goal" => "Goal", "verification" => "string" }].to_json
        File.write(json_file_path, json)

        expect {
          described_class.load_json(json_file_path)
        }.to raise_error(RSpec::Agents::ScenarioLoader::ValidationError, /field 'verification' must be Hash/)
      end
    end

    context "with valid optional fields" do
      it "accepts scenario with all fields" do
        json = [{
          "name"         => "Test",
          "goal"         => "Goal",
          "context"      => ["Context"],
          "personality"  => "Professional",
          "verification" => { "key" => "value" }
        }].to_json
        File.write(json_file_path, json)

        scenarios = described_class.load_json(json_file_path)

        expect(scenarios.size).to eq(1)
        expect(scenarios.first[:context]).to eq(["Context"])
        expect(scenarios.first[:personality]).to eq("Professional")
        expect(scenarios.first[:verification]).to eq({ "key" => "value" })
      end

      it "accepts scenario with only required fields" do
        json = [{ "name" => "Test", "goal" => "Goal" }].to_json
        File.write(json_file_path, json)

        scenarios = described_class.load_json(json_file_path)

        expect(scenarios.size).to eq(1)
        expect(scenarios.first[:name]).to eq("Test")
        expect(scenarios.first[:goal]).to eq("Goal")
      end
    end

    context "with non-hash scenario item" do
      it "raises ValidationError" do
        json = ["not a hash"].to_json
        File.write(json_file_path, json)

        expect {
          described_class.load_json(json_file_path)
        }.to raise_error(RSpec::Agents::ScenarioLoader::ValidationError, /must be a hash/)
      end
    end
  end

  describe "error messages" do
    it "includes scenario index in validation errors" do
      json = [
        { "name" => "Valid", "goal" => "Goal" },
        { "name" => "Invalid" }
      ].to_json
      File.write(json_file_path, json)

      expect {
        described_class.load_json(json_file_path)
      }.to raise_error(RSpec::Agents::ScenarioLoader::ValidationError, /at index 1/)
    end

    it "includes file path in error messages" do
      json = "{ invalid }"
      File.write(json_file_path, json)

      expect {
        described_class.load_json(json_file_path)
      }.to raise_error(RSpec::Agents::ScenarioLoader::LoadError, /#{Regexp.escape(json_file_path)}/)
    end
  end
end
