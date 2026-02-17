# RSpec::Agents - Alternative chatbot testing framework
# Implements the design from 2026_01_14_simulator-design-doc.md

# Core data classes
require_relative "agents/metadata"
require_relative "agents/tool_call"
require_relative "agents/agent_response"
require_relative "agents/message"
require_relative "agents/evaluation_result"

# Topic system
require_relative "agents/triggers"
require_relative "agents/topic"
require_relative "agents/topic_graph"

# Agent adapter
require_relative "agents/agents/base"

# LLM adapters
require_relative "agents/llm/base"
require_relative "agents/llm/response"
require_relative "agents/llm/anthropic"
require_relative "agents/llm/mock"

# Prompt builders
require_relative "agents/prompt_builders/base"
require_relative "agents/prompt_builders/criterion_evaluation"
require_relative "agents/prompt_builders/topic_classification"
require_relative "agents/prompt_builders/grounding_evaluation"
require_relative "agents/prompt_builders/user_simulation"
require_relative "agents/prompt_builders/intent_evaluation"
require_relative "agents/prompt_builders/goal_achievement_evaluation"

# Criterion (unified criterion wrapper)
require_relative "agents/criterion"

# Judge
require_relative "agents/judge"

# Conversation tracking
require_relative "agents/turn"
require_relative "agents/conversation"

# Event system
require_relative "agents/events"
require_relative "agents/event_bus"
require_relative "agents/observers/base"
require_relative "agents/observers/terminal_observer"
require_relative "agents/observers/rpc_notify_observer"
require_relative "agents/observers/parallel_terminal_observer"

# Turn execution
require_relative "agents/turn_executor"
require_relative "agents/runners/user_simulator"

# Shared helpers
require_relative "agents/backtrace_helper"

# Spec Executor (unified execution engine)
require_relative "agents/spec_executor"

# Runners
require_relative "agents/runners/terminal_runner"
require_relative "agents/runners/headless_runner"
require_relative "agents/runners/parallel_terminal_runner"

# Parallel execution
require_relative "agents/parallel/run_result"
require_relative "agents/parallel/example_discovery"
require_relative "agents/parallel/partitioner"
require_relative "agents/parallel/controller"

# Serialization
require_relative "agents/serialization"
require_relative "agents/serialization/run_data_builder"
require_relative "agents/serialization/test_suite_renderer"

# Scenario system
require_relative "agents/scenario"
require_relative "agents/scenario_loader"
require_relative "agents/stable_example_id"

# Configuration and DSL
require_relative "agents/simulator_config"
require_relative "agents/dsl"

# Matchers
require_relative "agents/matchers"

module RSpec
  module Agents
    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration) if block_given?
      end

      def reset_configuration!
        @configuration = Configuration.new
      end

      # Set up RSpec integration
      # Call this in spec_helper or rails_helper
      def setup_rspec!
        return unless defined?(::RSpec)

        ::RSpec.configure do |config|
          # Include DSL for agent tests
          config.include RSpec::Agents::DSL, type: :agent

          # Include matchers globally or for specific test types
          config.include RSpec::Agents::Matchers, type: :agent
        end
      end
    end

    class Configuration
      attr_accessor :agent, :llm, :cache_dir, :cache_enabled, :html_extensions

      def initialize
        @agent           = nil
        @llm             = nil
        @cache_dir       = nil
        @cache_enabled   = false
        @html_extensions = []
      end

      # Convenience method to set up a mock LLM
      def use_mock_llm!
        @llm = Llm::Mock.new
      end

      # Convenience method to set up Anthropic LLM
      def use_anthropic!(model: nil, api_key: nil)
        options = {}
        options[:model] = model if model
        options[:api_key] = api_key if api_key
        @llm = Llm::Anthropic.new(**options)
      end
    end
  end
end
# Auto-setup if RSpec is loaded
RSpec::Agents.setup_rspec! if defined?(::RSpec)
