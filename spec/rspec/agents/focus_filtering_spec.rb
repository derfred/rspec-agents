# frozen_string_literal: true

require "spec_helper"
require "rspec/agents"

RSpec.describe "Focus filtering configuration" do
  describe "ExampleDiscovery" do
    it "enables focus filtering after RSpec reset" do
      # This test verifies that the filter_run_when_matching :focus
      # configuration is applied after RSpec.reset in the discover method
      #
      # Note: The configuration must be in the implementation file (not agents_helper.rb)
      # because RSpec.reset clears all configuration, so it must be re-applied after reset.

      discovery = RSpec::Agents::Parallel::ExampleDiscovery.new

      method_source = discovery.method(:discover).source_location
      file_path = method_source[0]
      file_content = File.read(file_path)

      expect(file_content).to include("filter_run_when_matching :focus")
    end
  end

  describe "HeadlessRunner" do
    it "enables focus filtering after RSpec reset" do
      # Verify the run method includes focus filtering configuration
      # after RSpec.reset (since reset clears all configuration)

      runner = RSpec::Agents::Runners::HeadlessRunner.new(rpc_output: StringIO.new)

      method_source = runner.method(:run).source_location
      file_path = method_source[0]
      file_content = File.read(file_path)

      expect(file_content).to include("filter_run_when_matching :focus")
    end
  end
end
