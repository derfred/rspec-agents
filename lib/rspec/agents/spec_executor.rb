# frozen_string_literal: true

require "async"
require "rspec/core"
require "stringio"
require "digest"
require_relative "backtrace_helper"

module RSpec
  module Agents
    # Base class for spec execution engines.
    # Provides a common interface and shared functionality for both parallel and sequential execution.
    #
    # This is a reusable execution primitive consumed by CLI runners, agents-studio jobs,
    # and any other component that needs to execute specs and receive events.
    #
    # Use the subclasses directly:
    # - ParallelSpecExecutor for parallel execution across worker processes
    # - SequentialSpecExecutor for single-threaded in-process execution
    #
    # @example Parallel execution
    #   executor = ParallelSpecExecutor.new(worker_count: 4)
    #   executor.on_example_started { |event| puts "Started: #{event.description}" }
    #   executor.on_example_completed { |event, run_data| puts "Completed: #{event.description}" }
    #   executor.on_progress { |c, t, f| puts "Progress: #{c}/#{t}" }
    #
    #   result = Async { |task| executor.execute(["spec/"], task: task) }
    #   puts result.success? ? "All passed" : "Failures: #{result.failure_count}"
    #
    # @example Sequential execution
    #   executor = SequentialSpecExecutor.new
    #   executor.on_event { |type, event| puts "#{type}: #{event}" }
    #
    #   result = executor.execute(["spec/my_spec.rb"])
    #   puts result.success? ? "Passed" : "Failed"
    #
    class SpecExecutor
      include BacktraceHelper

      attr_reader :run_data, :event_bus

      # @param fail_fast [Boolean] Stop on first failure
      def initialize(fail_fast: false)
        @fail_fast = fail_fast

        @example_started_callbacks = []
        @example_completed_callbacks = []
        @progress_callbacks = []
        @event_callbacks = []

        @cancelled = false

        # Set up event bus and run data builder
        @event_bus = EventBus.new
        @run_data_builder = Serialization::RunDataBuilder.new(event_bus: @event_bus)
      end

      # Register callback for each example start.
      # @yield [event] Called after each ExampleStarted event
      def on_example_started(&block)
        @example_started_callbacks << block
      end

      # Register callback for each example completion.
      # @yield [event, run_data] Called after each ExamplePassed/Failed/Pending
      def on_example_completed(&block)
        @example_completed_callbacks << block
      end

      # Register callback for progress updates.
      # @yield [completed, total, failures]
      def on_progress(&block)
        @progress_callbacks << block
      end

      # Register callback for raw events (all event types).
      # @yield [type, event] type is String ("ExampleStarted", etc.), event is typed Events::*
      def on_event(&block)
        @event_callbacks << block
      end

      # Execute specs.
      # @param spec_paths [Array<String>] File paths, directories, or RSpec IDs
      # @param task [Async::Task, nil] Required for parallel mode
      # @return [RunResult]
      def execute(spec_paths, task: nil)
        raise NotImplementedError, "Subclasses must implement #execute"
      end

      # Cancel a running execution.
      def cancel
        @cancelled = true
      end

      # Access the current RunData (available during and after execution).
      # @return [Serialization::RunData, nil]
      def run_data
        @run_data_builder.run_data
      end

      protected

      # --- Callback Helpers ---

      def publish_event(type, event)
        @event_bus.publish(event)
        fire_event_callbacks(type, event)
      end

      def fire_event_callbacks(type, event)
        @event_callbacks.each { |cb| cb.call(type, event) }
      end

      def fire_example_started_callbacks(event)
        @example_started_callbacks.each { |cb| cb.call(event) }
      end

      def fire_example_completed_callbacks(event)
        @example_completed_callbacks.each { |cb| cb.call(event, run_data) }
      end

      def fire_progress_callbacks(completed, total, failures)
        @progress_callbacks.each { |cb| cb.call(completed, total, failures) }
      end

      def completion_event?(type)
        ["ExamplePassed", "ExampleFailed", "ExamplePending"].include?(type)
      end

      # --- Utility Methods ---

      def generate_example_id(example)
        Digest::SHA256.hexdigest(example.full_description)[0, 12]
      end

      def build_stable_example_id(example)
        scenario = example.metadata[:rspec_agents_scenario]
        StableExampleId.generate(example, scenario: scenario)
      rescue => e
        warn "[SpecExecutor] Failed to generate stable example ID: #{e.message}"
        nil
      end

    end

    # Parallel spec executor that runs specs across multiple worker processes.
    # Uses ParallelSpecController internally.
    #
    # @example
    #   executor = ParallelSpecExecutor.new(worker_count: 4, fail_fast: true)
    #   executor.on_example_started { |event| puts "Started: #{event.description}" }
    #   executor.on_example_completed { |event, run_data| puts "Done: #{event.description}" }
    #   executor.on_progress { |c, t, f| puts "#{c}/#{t} (#{f} failures)" }
    #
    #   result = Async { |task| executor.execute(["spec/"], task: task) }
    #
    class ParallelSpecExecutor < SpecExecutor
      # @param worker_count [Integer] Number of parallel workers
      # @param fail_fast [Boolean] Stop on first failure
      def initialize(worker_count: 4, fail_fast: false)
        super(fail_fast: fail_fast)
        @worker_count = worker_count
        @controller = nil
      end

      # Execute specs in parallel.
      # @param spec_paths [Array<String>] File paths, directories, or RSpec IDs
      # @param task [Async::Task] Required - the Async task context
      # @return [RunResult]
      def execute(spec_paths, task:)
        raise ArgumentError, "task is required for parallel execution" unless task

        @cancelled = false
        @controller = Parallel::ParallelSpecController.new(
          worker_count: @worker_count,
          fail_fast:    @fail_fast
        )

        # Track progress for callbacks
        @total_examples = 0
        @completed_examples = 0
        @failure_count = 0

        # Wire up event handling
        @controller.on_event do |type, payload|
          handle_parallel_event(type, payload)
        end

        @controller.on_progress do |completed, total, failures|
          @completed_examples = completed
          @total_examples = total
          @failure_count = failures
          fire_progress_callbacks(completed, total, failures)
        end

        # Start and execute
        @controller.start(spec_paths)
        @controller.execute(task: task)

        @controller.results
      end

      # Cancel a running execution.
      def cancel
        super
        @controller&.cancel
      end

      private

      def handle_parallel_event(type, payload)
        # Reconstruct typed event from serialized form
        event = Events.from_hash(type, payload)
        return unless event

        # Publish to event bus for RunDataBuilder
        @event_bus.publish(event)

        # Fire raw event callbacks
        fire_event_callbacks(type, event)

        # Fire example started callback
        if type == "ExampleStarted"
          fire_example_started_callbacks(event)
        end

        # Fire example completed callbacks for completion events
        if completion_event?(type)
          fire_example_completed_callbacks(event)
        end
      end
    end

    # Sequential spec executor that runs specs in-process using RSpec's Ruby API.
    # Single-threaded, synchronous execution.
    #
    # @example
    #   executor = SequentialSpecExecutor.new
    #   executor.on_example_started { |event| puts "Started: #{event.description}" }
    #   executor.on_example_completed { |event, run_data| puts "Done: #{event.description}" }
    #   executor.on_event { |type, event| puts "#{type}" }
    #
    #   result = executor.execute(["spec/my_spec.rb"])
    #
    class SequentialSpecExecutor < SpecExecutor
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

      def initialize(fail_fast: false)
        super
        @group_stack = []
      end

      # Execute specs sequentially in-process.
      # @param spec_paths [Array<String>] File paths or RSpec CLI arguments
      # @param task [Async::Task, nil] Ignored - not needed for sequential execution
      # @return [RunResult]
      def execute(spec_paths, task: nil)
        @cancelled = false
        args = Array(spec_paths)

        # Reset RSpec state for clean run
        RSpec.reset
        RSpec.configuration.reset

        # Re-register DSL after reset
        RSpec::Agents.setup_rspec!

        # Configure output streams to suppress RSpec's default output
        null_output = StringIO.new
        RSpec.configuration.output_stream = null_output
        RSpec.configuration.error_stream = $stderr

        # Parse options
        options = RSpec::Core::ConfigurationOptions.new(args)
        options.configure(RSpec.configuration)

        # Re-suppress output stream after options configure
        RSpec.configuration.output_stream = null_output

        # Suppress default formatters
        RSpec.configuration.formatters.clear

        # Register ourselves as a listener
        RSpec.configuration.reporter.register_listener(self, *NOTIFICATIONS)

        # Set event bus for the current thread so Conversation (via TestContext)
        # publishes to the same bus that RunDataBuilder listens on.
        EventBus.current = @event_bus

        # Create runner and execute
        runner = RSpec::Core::Runner.new(options)
        exit_code = runner.run($stderr, null_output)

        # Clean up thread-locals
        EventBus.current = nil

        # Build result
        Parallel::RunResult.new(
          success:            exit_code == 0,
          example_count:      @run_data_builder.run_data&.examples&.size || 0,
          failure_count:      count_failures,
          completed_examples: @run_data_builder.run_data&.examples&.keys || []
        )
      end

      # Cancel is not supported for sequential execution (single-threaded, synchronous)
      def cancel
        super
        # No-op: sequential execution cannot be cancelled mid-run
      end

      # --- RSpec Notification Handlers ---

      def start(notification)
        event = Events::SuiteStarted.new(
          example_count: notification.count,
          load_time:     notification.load_time,
          seed:          RSpec.configuration.seed,
          time:          Time.now
        )
        publish_event("SuiteStarted", event)
        @total_examples = notification.count
        @completed_examples = 0
        @failure_count = 0
      end

      def example_group_started(notification)
        group = notification.group
        @group_stack.push(group.description)

        event = Events::GroupStarted.new(
          description: group.description,
          file_path:   group.metadata[:file_path],
          line_number: group.metadata[:line_number],
          time:        Time.now
        )
        publish_event("GroupStarted", event)
      end

      def example_group_finished(notification)
        @group_stack.pop

        event = Events::GroupFinished.new(
          description: notification.group.description,
          time:        Time.now
        )
        publish_event("GroupFinished", event)
      end

      def example_started(notification)
        example = notification.example

        # Generate stable example ID and store in thread-local
        stable_id_obj = build_stable_example_id(example)
        example_id = stable_id_obj&.hash_value || generate_example_id(example)
        Thread.current[:rspec_agents_example_id] = example_id
        Thread.current[:rspec_agents_stable_id] = stable_id_obj&.to_s

        scenario = example.metadata[:rspec_agents_scenario]
        event = Events::ExampleStarted.new(
          example_id:       example_id,
          stable_id:        stable_id_obj&.to_s,
          canonical_path:   stable_id_obj&.canonical_path,
          description:      example.description,
          full_description: example.full_description,
          location:         example.location,
          scenario:         scenario,
          time:             Time.now
        )
        publish_event("ExampleStarted", event)
        fire_example_started_callbacks(event)
      end

      def example_passed(notification)
        example_id = Thread.current[:rspec_agents_example_id]
        stable_id = Thread.current[:rspec_agents_stable_id]
        Thread.current[:rspec_agents_example_id] = nil
        Thread.current[:rspec_agents_stable_id] = nil
        example = notification.example

        event = Events::ExamplePassed.new(
          example_id:       example_id,
          stable_id:        stable_id,
          description:      example.description,
          full_description: example.full_description,
          duration:         example.execution_result.run_time,
          time:             Time.now
        )
        publish_event("ExamplePassed", event)
        fire_example_completed_callbacks(event)

        @completed_examples += 1
        fire_progress_callbacks(@completed_examples, @total_examples, @failure_count)
      end

      def example_failed(notification)
        example_id = Thread.current[:rspec_agents_example_id]
        stable_id = Thread.current[:rspec_agents_stable_id]
        Thread.current[:rspec_agents_example_id] = nil
        Thread.current[:rspec_agents_stable_id] = nil
        example = notification.example
        message = extract_failure_message(notification)
        backtrace = extract_backtrace(notification)

        event = Events::ExampleFailed.new(
          example_id:       example_id,
          stable_id:        stable_id,
          description:      example.description,
          full_description: example.full_description,
          location:         example.location,
          duration:         example.execution_result.run_time,
          message:          message,
          backtrace:        backtrace,
          time:             Time.now
        )
        publish_event("ExampleFailed", event)
        fire_example_completed_callbacks(event)

        @completed_examples += 1
        @failure_count += 1
        fire_progress_callbacks(@completed_examples, @total_examples, @failure_count)
      end

      def example_pending(notification)
        example_id = Thread.current[:rspec_agents_example_id]
        stable_id = Thread.current[:rspec_agents_stable_id]
        Thread.current[:rspec_agents_example_id] = nil
        Thread.current[:rspec_agents_stable_id] = nil
        example = notification.example

        event = Events::ExamplePending.new(
          example_id:       example_id,
          stable_id:        stable_id,
          description:      example.description,
          full_description: example.full_description,
          message:          example.execution_result.pending_message,
          time:             Time.now
        )
        publish_event("ExamplePending", event)
        fire_example_completed_callbacks(event)

        @completed_examples += 1
        fire_progress_callbacks(@completed_examples, @total_examples, @failure_count)
      end

      def stop(_notification)
        event = Events::SuiteStopped.new(time: Time.now)
        publish_event("SuiteStopped", event)
      end

      def dump_summary(notification)
        event = Events::SuiteSummary.new(
          duration:      notification.duration,
          example_count: notification.example_count,
          failure_count: notification.failure_count,
          pending_count: notification.pending_count,
          time:          Time.now
        )
        publish_event("SuiteSummary", event)
      end

      private

      def count_failures
        return 0 unless @run_data_builder.run_data
        @run_data_builder.run_data.examples.values.count { |ex| ex.status == :failed }
      end
    end
  end
end
