# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "metadata"

# Event Serialization System
#
# Provides data structures for capturing and persisting test run data.
# See 2026_01_27_event_serialization-design.md for architecture details.

module RSpec
  module Agents
    module Serialization
      ALPINE_VERSION = "3.14.8"

      # Shared serialization helpers
      module SerializationHelpers
        def serialize_value(value)
          case value
          when nil then nil
          when Time then value.iso8601(3)
          when Array then value.map { |v| serialize_value(v) }
          when Hash then value.transform_values { |v| serialize_value(v) }
          when ->(v) { v.respond_to?(:to_h) && !v.is_a?(Hash) } then value.to_h
          else value
          end
        end

        def parse_time(value)
          return nil unless value
          value.is_a?(Time) ? value : Time.parse(value)
        end

        def get(hash, key)
          return hash[key] if hash.key?(key)
          hash[key.to_s]
        end

        def get_array(hash, key)
          get(hash, key) || []
        end

        def wrap_metadata(value)
          value.is_a?(Metadata) ? value : Metadata.new(value || {})
        end
      end

      # For Data.define classes - provides to_h with serialization
      module DataClassMethods
        include SerializationHelpers

        def to_h
          members.each_with_object({}) do |key, hash|
            hash[key] = serialize_value(send(key))
          end
        end
      end

      # Class methods for from_h on Data.define classes
      module DataClassFromH
        include SerializationHelpers
      end

      # =========================================================================
      # Immutable Data Classes
      # =========================================================================

      ExceptionData = Data.define(:class_name, :message, :backtrace) do
        include DataClassMethods
        extend DataClassFromH

        def initialize(class_name:, message:, backtrace: [])
          super(class_name: class_name, message: message, backtrace: Array(backtrace).first(10))
        end

        def self.from_h(hash)
          return nil unless hash
          new(class_name: get(hash, :class_name), message: get(hash, :message), backtrace: get_array(hash, :backtrace))
        end
      end

      MessageData = Data.define(:role, :content, :timestamp, :source, :metadata) do
        include DataClassMethods
        extend DataClassFromH

        def initialize(role:, content:, timestamp:, source: nil, metadata: {})
          super(role: role.to_s, content: content, timestamp: timestamp, source: source&.to_s, metadata: wrap_metadata(metadata))
        end

        def self.from_h(hash)
          return nil unless hash
          new(role: get(hash, :role), content: get(hash, :content), timestamp: parse_time(get(hash, :timestamp)),
              source: get(hash, :source), metadata: get(hash, :metadata) || {})
        end
      end

      ToolCallData = Data.define(:name, :arguments, :result, :error, :timestamp, :metadata) do
        include DataClassMethods
        extend DataClassFromH

        def initialize(name:, arguments:, timestamp:, result: nil, error: nil, metadata: {})
          super(name: name.to_s, arguments: arguments || {}, result: result, error: error,
                timestamp: timestamp, metadata: wrap_metadata(metadata))
        end

        def self.from_h(hash)
          return nil unless hash
          new(name: get(hash, :name), arguments: get(hash, :arguments) || {}, result: get(hash, :result),
              error: get(hash, :error), timestamp: parse_time(get(hash, :timestamp)), metadata: get(hash, :metadata) || {})
        end
      end

      EvaluationData = Data.define(:name, :description, :passed, :reasoning, :timestamp, :mode, :type, :failure_message, :metadata) do
        include DataClassMethods
        extend DataClassFromH

        def initialize(name:, description:, passed:, timestamp:, reasoning: nil, mode: nil, type: nil, failure_message: nil, metadata: {})
          super(name: name, description: description, passed: passed, reasoning: reasoning,
                timestamp: timestamp, mode: mode&.to_sym, type: type&.to_sym, failure_message: failure_message,
                metadata: wrap_metadata(metadata))
        end

        # Whether this is a soft evaluation (quality metric, doesn't affect test pass/fail)
        def soft?
          mode == :soft
        end

        # Whether this is a hard expectation (affects test pass/fail)
        def hard?
          mode == :hard
        end

        def self.from_h(hash)
          return nil unless hash
          new(name: get(hash, :name), description: get(hash, :description), passed: get(hash, :passed),
              reasoning: get(hash, :reasoning), timestamp: parse_time(get(hash, :timestamp)),
              mode: get(hash, :mode)&.to_sym, type: get(hash, :type)&.to_sym,
              failure_message: get(hash, :failure_message), metadata: get(hash, :metadata) || {})
        end
      end

      # Scenario data for serialization
      # Captures the scenario definition used in a test
      ScenarioData = Data.define(:id, :name, :goal, :personality, :context, :verification, :data) do
        include DataClassMethods
        extend DataClassFromH

        def initialize(id:, name:, goal:, personality: nil, context: nil, verification: nil, data: {})
          super(id: id, name: name, goal: goal, personality: personality,
                context: context, verification: verification, data: data || {})
        end

        def self.from_h(hash)
          return nil unless hash
          new(
            id:           get(hash, :id),
            name:         get(hash, :name),
            goal:         get(hash, :goal),
            personality:  get(hash, :personality),
            context:      get(hash, :context),
            verification: get(hash, :verification),
            data:         get(hash, :data) || {}
          )
        end

        # Create from a Scenario object
        def self.from_scenario(scenario)
          return nil unless scenario
          new(
            id:           scenario.identifier,
            name:         scenario[:name] || scenario[:id],
            goal:         scenario[:goal],
            personality:  scenario[:personality],
            context:      scenario[:context],
            verification: scenario[:verification],
            data:         scenario.to_h
          )
        end
      end

      SummaryStats = Data.define(:example_count, :passed_count, :failed_count, :pending_count, :total_duration_ms) do
        include DataClassMethods
      end

      # =========================================================================
      # Mutable Data Classes (built incrementally during test execution)
      # =========================================================================

      class TurnData
        include SerializationHelpers
        extend DataClassFromH

        attr_reader :number, :user_message, :metadata
        attr_accessor :agent_response, :tool_calls

        def initialize(number:, user_message:, agent_response: nil, tool_calls: [], topic: nil, metadata: {})
          @number = number
          @user_message = user_message
          @agent_response = agent_response
          @tool_calls = tool_calls || []
          @topic = topic&.to_s
          @metadata = wrap_metadata(metadata)
        end

        def topic=(value)
          @topic = value&.to_s
        end

        attr_reader :topic

        def to_h
          { number: @number, user_message: @user_message&.to_h, agent_response: @agent_response&.to_h,
            tool_calls: @tool_calls.map(&:to_h), topic: @topic, metadata: @metadata.to_h }
        end

        def self.from_h(hash)
          return nil unless hash
          new(number: get(hash, :number), user_message: MessageData.from_h(get(hash, :user_message)),
              agent_response: MessageData.from_h(get(hash, :agent_response)),
              tool_calls: get_array(hash, :tool_calls).map { |tc| ToolCallData.from_h(tc) },
              topic: get(hash, :topic), metadata: get(hash, :metadata) || {})
        end
      end

      class ConversationData
        include SerializationHelpers
        extend DataClassFromH

        attr_reader :started_at, :turns, :metadata
        attr_accessor :ended_at, :final_topic

        def initialize(started_at:, ended_at: nil, turns: [], final_topic: nil, metadata: {})
          @started_at = started_at
          @ended_at = ended_at
          @turns = turns || []
          @final_topic = final_topic&.to_s
          @metadata = wrap_metadata(metadata)
        end

        def add_turn(turn) = @turns << turn
        def current_turn = @turns.last

        def to_h
          { started_at: serialize_value(@started_at), ended_at: serialize_value(@ended_at),
            turns: @turns.map(&:to_h), final_topic: @final_topic, metadata: @metadata.to_h }
        end

        def self.from_h(hash)
          return nil unless hash
          new(started_at: parse_time(get(hash, :started_at)), ended_at: parse_time(get(hash, :ended_at)),
              turns: get_array(hash, :turns).map { |t| TurnData.from_h(t) },
              final_topic: get(hash, :final_topic), metadata: get(hash, :metadata) || {})
        end
      end

      class ExampleData
        include SerializationHelpers
        extend DataClassFromH

        attr_reader :id, :stable_id, :canonical_path, :file, :description, :location, :started_at, :evaluations, :metadata
        attr_accessor :status, :finished_at, :duration_ms, :exception, :conversation, :scenario_id

        def initialize(id:, file:, description:, location:, started_at:, status: :pending,
                       stable_id: nil, canonical_path: nil, scenario_id: nil,
                       finished_at: nil, duration_ms: nil, exception: nil, conversation: nil, evaluations: [], metadata: {})
          @id, @file, @description, @location = id, file, description, location
          @stable_id, @canonical_path = stable_id, canonical_path
          @scenario_id = scenario_id
          @status, @started_at, @finished_at, @duration_ms = status.to_sym, started_at, finished_at, duration_ms
          @exception, @conversation, @evaluations = exception, conversation, evaluations || []
          @metadata = wrap_metadata(metadata)
        end

        def add_evaluation(evaluation) = @evaluations << evaluation

        def to_h
          { id: @id, stable_id: @stable_id, canonical_path: @canonical_path, scenario_id: @scenario_id,
            file: @file, description: @description, location: @location, status: @status.to_s,
            started_at: serialize_value(@started_at), finished_at: serialize_value(@finished_at),
            duration_ms: @duration_ms, exception: @exception&.to_h, conversation: @conversation&.to_h,
            evaluations: @evaluations.map(&:to_h), metadata: @metadata.to_h }
        end

        def self.from_h(hash)
          return nil unless hash
          new(id: get(hash, :id), stable_id: get(hash, :stable_id), canonical_path: get(hash, :canonical_path),
              scenario_id: get(hash, :scenario_id),
              file: get(hash, :file), description: get(hash, :description),
              location: get(hash, :location), status: get(hash, :status)&.to_sym || :pending,
              started_at: parse_time(get(hash, :started_at)), finished_at: parse_time(get(hash, :finished_at)),
              duration_ms: get(hash, :duration_ms), exception: ExceptionData.from_h(get(hash, :exception)),
              conversation: ConversationData.from_h(get(hash, :conversation)),
              evaluations: get_array(hash, :evaluations).map { |e| EvaluationData.from_h(e) },
              metadata: get(hash, :metadata) || {})
        end
      end

      class RunData
        include SerializationHelpers
        extend DataClassFromH

        attr_reader :run_id, :started_at, :seed, :examples, :scenarios
        attr_accessor :finished_at

        def initialize(run_id:, started_at:, finished_at: nil, seed: nil, examples: {}, scenarios: {})
          @run_id, @started_at, @finished_at, @seed = run_id, started_at, finished_at, seed
          @examples = examples || {}
          @scenarios = scenarios || {}
        end

        def add_example(example_data) = @examples[example_data.id] = example_data
        def example(id) = @examples[id]

        # Register a scenario in the scenarios hash
        # @param scenario_data [ScenarioData] The scenario to register
        # @return [String] The scenario ID
        def register_scenario(scenario_data)
          return nil unless scenario_data
          @scenarios[scenario_data.id] = scenario_data unless @scenarios.key?(scenario_data.id)
          scenario_data.id
        end

        # Get a scenario by ID
        # @param id [String] The scenario ID
        # @return [ScenarioData, nil]
        def scenario(id)
          @scenarios[id]
        end

        def summary
          counts = @examples.each_value.with_object(passed: 0, failed: 0, pending: 0, duration: 0) do |ex, c|
            c[ex.status] += 1 if c.key?(ex.status)
            c[:duration] += ex.duration_ms.to_i
          end
          SummaryStats.new(example_count: @examples.size, passed_count: counts[:passed],
                           failed_count: counts[:failed], pending_count: counts[:pending],
                           total_duration_ms: counts[:duration])
        end

        def to_h
          { run_id: @run_id, started_at: serialize_value(@started_at), finished_at: serialize_value(@finished_at),
            seed: @seed, scenarios: @scenarios.transform_values(&:to_h), examples: @examples.transform_values(&:to_h) }
        end

        def self.from_h(hash)
          return nil unless hash
          new(run_id: get(hash, :run_id), started_at: parse_time(get(hash, :started_at)),
              finished_at: parse_time(get(hash, :finished_at)), seed: get(hash, :seed),
              scenarios: (get(hash, :scenarios) || {}).transform_values { |s| ScenarioData.from_h(s) },
              examples: (get(hash, :examples) || {}).transform_values { |e| ExampleData.from_h(e) })
        end
      end

      # =========================================================================
      # JsonFile - Simple JSON file read/write utility
      # =========================================================================

      class JsonFile
        class << self
          def write(path, run_data)
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, JSON.pretty_generate(run_data.to_h))
          end

          def read(path)
            RunData.from_h(JSON.parse(File.read(path)))
          end
        end
      end
    end
  end
end
