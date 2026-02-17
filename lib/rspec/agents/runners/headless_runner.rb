# frozen_string_literal: true

require "rspec/core"
require "stringio"
require "digest"
require "json"

module RSpec
  module Agents
    module Runners
      # In-worker RSpec execution that emits events via EventBus.
      # Used by parallel_spec_worker to run specs in subprocess with event streaming.
      #
      # All events (both RSpec lifecycle and conversation events) flow through
      # the EventBus, which RpcNotifyObserver forwards to the controller.
      #
      # Event flow:
      #   RSpec notification → HeadlessRunner → EventBus#publish(typed event)
      #   Conversation turn  → Conversation   → EventBus#publish(typed event)
      #   EventBus           → RpcNotifyObserver → JSON over RPC socket
      #
      class HeadlessRunner
        include BacktraceHelper
        # RSpec notifications we subscribe to
        NOTIFICATIONS = [
          :start,
          :example_group_started,
          :example_group_finished,
          :example_started,
          :example_passed,
          :example_failed,
          :example_pending,
          :stop,
          :dump_summary
        ].freeze

        # @param rpc_output [IO] Output stream for RPC notifications (socket)
        def initialize(rpc_output:)
          @rpc_output = rpc_output
          @example_count = 0
          @failure_count = 0
        end

        # Run the specified examples
        #
        # @param example_ids [Array<String>] RSpec example IDs (e.g., "spec/file.rb[1:1]")
        # @return [Hash] Result with exit_code, example_count, failure_count
        def run(example_ids)
          @example_count = 0
          @failure_count = 0

          # Create EventBus for this worker
          @event_bus = EventBus.new

          # Set up RPC forwarding - all events go through this observer
          Observers::RpcNotifyObserver.new(
            rpc_output: @rpc_output,
            event_bus:  @event_bus
          )

          # Reset RSpec state for clean run
          RSpec.reset
          RSpec.configuration.reset

          # Re-register DSL after reset (reset wipes out config.include calls)
          RSpec::Agents.setup_rspec!

          # Enable focus filtering (fit/fdescribe/fcontext)
          # This must be set after RSpec.reset since reset clears all configuration
          RSpec.configuration.filter_run_when_matching :focus

          # Configure output streams
          null_output = StringIO.new
          RSpec.configuration.output_stream = null_output
          RSpec.configuration.error_stream = $stderr

          # Parse options with example filter
          options = RSpec::Core::ConfigurationOptions.new(example_ids)
          options.configure(RSpec.configuration)

          # Re-suppress output after options configure
          RSpec.configuration.output_stream = null_output
          RSpec.configuration.formatters.clear

          # Register ourselves as a listener for RSpec lifecycle events
          RSpec.configuration.reporter.register_listener(self, *NOTIFICATIONS)

          # Set event bus for the current thread so Conversation finds it
          EventBus.current = @event_bus

          # Run specs
          runner = RSpec::Core::Runner.new(options)
          exit_code = runner.run($stderr, null_output)

          # Clean up thread-locals
          EventBus.current = nil
          Thread.current[:rspec_agents_example_id] = nil

          {
            exit_code:     exit_code,
            example_count: @example_count,
            failure_count: @failure_count
          }
        end

        # --- RSpec Notification Handlers ---
        # Each handler creates a typed event and publishes it through the EventBus

        def start(notification)
          @event_bus.publish(Events::SuiteStarted.new(
            example_count: notification.count,
            load_time:     notification.load_time,
            seed:          RSpec.configuration.seed,
            time:          Time.now
          ))
        end

        def example_group_started(notification)
          group = notification.group
          @event_bus.publish(Events::GroupStarted.new(
            description: group.description,
            file_path:   group.metadata[:file_path],
            line_number: group.metadata[:line_number],
            time:        Time.now
          ))
        end

        def example_group_finished(notification)
          group = notification.group
          @event_bus.publish(Events::GroupFinished.new(
            description: group.description,
            time:        Time.now
          ))
        end

        def example_started(notification)
          example = notification.example
          @example_count += 1

          # Generate stable example ID and store in thread-local
          stable_id_obj = build_stable_example_id(example)
          example_id = stable_id_obj&.hash_value || generate_example_id(example)
          Thread.current[:rspec_agents_example_id] = example_id
          Thread.current[:rspec_agents_stable_id] = stable_id_obj&.to_s

          scenario = example.metadata[:rspec_agents_scenario]
          @event_bus.publish(Events::ExampleStarted.new(
            example_id:       example_id,
            stable_id:        stable_id_obj&.to_s,
            canonical_path:   stable_id_obj&.canonical_path,
            description:      example.description,
            full_description: example.full_description,
            location:         example.location,
            scenario:         scenario,
            time:             Time.now
          ))
        end

        def example_passed(notification)
          example_id = Thread.current[:rspec_agents_example_id]
          stable_id = Thread.current[:rspec_agents_stable_id]
          Thread.current[:rspec_agents_example_id] = nil
          Thread.current[:rspec_agents_stable_id] = nil
          example = notification.example

          @event_bus.publish(Events::ExamplePassed.new(
            example_id:       example_id,
            stable_id:        stable_id,
            description:      example.description,
            full_description: example.full_description,
            duration:         example.execution_result.run_time,
            time:             Time.now
          ))
        end

        def example_failed(notification)
          example_id = Thread.current[:rspec_agents_example_id]
          stable_id = Thread.current[:rspec_agents_stable_id]
          Thread.current[:rspec_agents_example_id] = nil
          Thread.current[:rspec_agents_stable_id] = nil
          example = notification.example
          @failure_count += 1

          @event_bus.publish(Events::ExampleFailed.new(
            example_id:       example_id,
            stable_id:        stable_id,
            description:      example.description,
            full_description: example.full_description,
            location:         example.location,
            duration:         example.execution_result.run_time,
            message:          extract_failure_message(notification),
            backtrace:        extract_backtrace(notification),
            time:             Time.now
          ))
        end

        def example_pending(notification)
          example_id = Thread.current[:rspec_agents_example_id]
          stable_id = Thread.current[:rspec_agents_stable_id]
          Thread.current[:rspec_agents_example_id] = nil
          Thread.current[:rspec_agents_stable_id] = nil
          example = notification.example

          @event_bus.publish(Events::ExamplePending.new(
            example_id:       example_id,
            stable_id:        stable_id,
            description:      example.description,
            full_description: example.full_description,
            message:          example.execution_result.pending_message,
            time:             Time.now
          ))
        end

        def stop(_notification)
          @event_bus.publish(Events::SuiteStopped.new(
            time: Time.now
          ))
        end

        def dump_summary(notification)
          @event_bus.publish(Events::SuiteSummary.new(
            duration:      notification.duration,
            example_count: notification.example_count,
            failure_count: notification.failure_count,
            pending_count: notification.pending_count,
            time:          Time.now
          ))
        end

        private

        def generate_example_id(example)
          Digest::SHA256.hexdigest(example.full_description)[0, 12]
        end

        def build_stable_example_id(example)
          scenario = example.metadata[:rspec_agents_scenario]
          StableExampleId.generate(example, scenario: scenario)
        rescue => e
          # Fall back gracefully if stable ID generation fails
          warn "[HeadlessRunner] Failed to generate stable example ID: #{e.message}"
          nil
        end

      end
    end
  end
end
