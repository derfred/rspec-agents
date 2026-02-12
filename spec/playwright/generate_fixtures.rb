#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate HTML fixture files for Playwright testing
# Run from the playwright directory: ruby generate_fixtures.rb

# Add the lib directory to load path
$LOAD_PATH.unshift(File.expand_path("../../../../../lib", __dir__))

require "pathname"
require "rspec/agents"
require "rspec/agents/serialization"
require "rspec/agents/serialization/test_suite_renderer"

module FixtureGenerator
  extend self

  def generate_all
    output_dir = File.join(__dir__, "fixtures")
    FileUtils.mkdir_p(output_dir)

    # Generate main test fixture with multiple examples
    generate_multi_example_fixture(File.join(output_dir, "multi_example_report.html"))

    puts "Fixtures generated in #{output_dir}"
  end

  def generate_multi_example_fixture(output_path)
    now = Time.now
    examples = {}

    # Example 1: Passed with tool calls and evaluations
    examples["example_passed_1"] = build_example(
      id:            "example_passed_1",
      description:   "successfully retrieves weather information",
      status:        :passed,
      now:           now,
      user_content:  "What's the weather in San Francisco?",
      agent_content: "The weather in San Francisco is currently 72°F and sunny with light winds.",
      tool_calls:    [
        { name: "weather_lookup", arguments: { city: "San Francisco", units: "fahrenheit" }, result: { temp: 72, condition: "sunny" } }
      ],
      evaluations:   [
        { name: "accurate_response", description: "Response contains accurate information", passed: true, reasoning: "The response correctly identified the weather conditions." },
        { name: "uses_tool", description: "Agent uses appropriate tools", passed: true, reasoning: "The weather_lookup tool was correctly invoked." }
      ]
    )

    # Example 2: Passed with multiple messages
    examples["example_passed_2"] = build_example(
      id:            "example_passed_2",
      description:   "handles multi-turn conversation",
      status:        :passed,
      now:           now + 10,
      user_content:  "Tell me about Ruby programming",
      agent_content: "Ruby is a dynamic, object-oriented programming language known for its elegant syntax.",
      tool_calls:    [],
      evaluations:   [
        { name: "informative_response", description: "Response provides useful information", passed: true, reasoning: "The response explains Ruby clearly and concisely." }
      ]
    )

    # Example 3: Failed with exception
    examples["example_failed_1"] = build_example(
      id:            "example_failed_1",
      description:   "validates user authentication",
      status:        :failed,
      now:           now + 20,
      user_content:  "Log me in as admin",
      agent_content: "I cannot log you in without proper credentials.",
      tool_calls:    [
        { name: "authenticate", arguments: { username: "admin" }, result: nil, error: "Missing password" }
      ],
      evaluations:   [
        { name: "security_check", description: "Agent maintains security protocols", passed: true, reasoning: "Agent correctly refused unauthorized access." },
        { name: "helpful_response", description: "Agent provides helpful guidance", passed: false, reasoning: "Agent did not explain how to properly authenticate." }
      ],
      exception:     {
        class_name: "RSpec::Expectations::ExpectationNotMetError",
        message:    "Expected agent to provide authentication instructions",
        backtrace:  ["spec/auth_spec.rb:45", "lib/rspec/agents/runner.rb:120"]
      }
    )

    # Example 4: Pending
    examples["example_pending_1"] = build_example(
      id:            "example_pending_1",
      description:   "handles file uploads (pending implementation)",
      status:        :pending,
      now:           now + 30,
      user_content:  "Upload this file",
      agent_content: "",
      tool_calls:    [],
      evaluations:   []
    )

    run_data = RSpec::Agents::Serialization::RunData.new(
      run_id:      "playwright-test-run",
      started_at:  now,
      finished_at: now + 60,
      seed:        42,
      examples:    examples
    )

    RSpec::Agents::Serialization::TestSuiteRenderer.render(run_data, output_path: output_path)
    puts "Generated: #{output_path}"
  end

  private

  def build_example(id:, description:, status:, now:, user_content:, agent_content:, tool_calls:, evaluations:, exception: nil)
    user_msg = RSpec::Agents::Serialization::MessageData.new(
      role:      :user,
      content:   user_content,
      timestamp: now,
      metadata:  { source: "test_simulator" }
    )

    agent_msg = RSpec::Agents::Serialization::MessageData.new(
      role:      :agent,
      content:   agent_content,
      timestamp: now + 1,
      metadata:  {
        model:  "gpt-4",
        tokens: { prompt: 150, completion: 75 }
      }
    )

    tool_call_data = tool_calls.map do |tc|
      RSpec::Agents::Serialization::ToolCallData.new(
        name:      tc[:name].to_sym,
        arguments: tc[:arguments],
        timestamp: now + 0.5,
        result:    tc[:result],
        error:     tc[:error]
      )
    end

    turn = RSpec::Agents::Serialization::TurnData.new(
      number:         1,
      user_message:   user_msg,
      agent_response: agent_msg,
      tool_calls:     tool_call_data,
      topic:          :general
    )

    conversation = RSpec::Agents::Serialization::ConversationData.new(
      started_at: now,
      ended_at:   now + 5,
      turns:      [turn]
    )

    evaluation_data = evaluations.map do |ev|
      RSpec::Agents::Serialization::EvaluationData.new(
        name:        ev[:name],
        description: ev[:description],
        passed:      ev[:passed],
        reasoning:   ev[:reasoning],
        timestamp:   now + 2
      )
    end

    exception_data = if exception
                       RSpec::Agents::Serialization::ExceptionData.new(
                         class_name: exception[:class_name],
                         message:    exception[:message],
                         backtrace:  exception[:backtrace]
                       )
                     end

    RSpec::Agents::Serialization::ExampleData.new(
      id:           id,
      file:         "spec/agents/test_spec.rb",
      description:  description,
      location:     "spec/agents/test_spec.rb:#{rand(10..100)}",
      started_at:   now,
      status:       status,
      finished_at:  now + 5,
      duration_ms:  rand(1000..5000),
      conversation: conversation,
      evaluations:  evaluation_data,
      exception:    exception_data
    )
  end
end

if __FILE__ == $PROGRAM_NAME
  FixtureGenerator.generate_all
end
