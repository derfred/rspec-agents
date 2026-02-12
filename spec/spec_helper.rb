# frozen_string_literal: true

require "rspec/agents"

RSpec.configure do |config|
  config.example_status_persistence_file_path = "spec_status"
  config.filter_run_when_matching :focus unless ENV["CI"] == "true"
  config.raise_errors_for_deprecations!
end

RSpec::Agents.setup_rspec!
