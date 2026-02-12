# frozen_string_literal: true

require "async"
require "rbconfig"
require_relative "../../../async_workers"
require_relative "example_discovery"
require_relative "partitioner"
require_relative "run_result"

module RSpec
  module Agents
    module Parallel
      # Central orchestrator for parallel spec execution.
      # Spawns worker processes, distributes examples, and aggregates events.
      #
      # @example Terminal mode
      #   controller = ParallelSpecController.new(worker_count: 4)
      #   controller.on_event { |type, payload| puts "#{type}: #{payload}" }
      #   controller.start(["spec/"])
      #   result = controller.wait
      #   puts "Success: #{result.success?}"
      #
      # @example Embedded mode (async context)
      #   Async do
      #     controller = ParallelSpecController.new(worker_count: 4)
      #     controller.on_progress { |c, t, f| update_ui(c, t, f) }
      #     controller.start(["spec/"])
      #     controller.wait
      #   end
      #
      class ParallelSpecController
        attr_reader :status, :results

        # @param worker_count [Integer] Number of parallel workers
        # @param fail_fast [Boolean] Stop all workers on first failure
        def initialize(worker_count:, fail_fast: false)
          @worker_count = worker_count
          @fail_fast = fail_fast
          @status = :idle
          @results = nil

          @event_callbacks = []
          @progress_callbacks = []

          # Per-example event buffers
          @example_buffers = Hash.new { |h, k| h[k] = [] }
          @completed_examples = []
          @failure_count = 0
          @total_examples = 0
          @mutex = Mutex.new
        end

        # Register callback for events (embedded mode)
        # @yield [event_type, payload] Called for each event
        def on_event(&block)
          @event_callbacks << block
        end

        # Register callback for progress updates
        # @yield [completed, total, failures] Called on example completion
        def on_progress(&block)
          @progress_callbacks << block
        end

        # Start a test run
        # @param spec_paths [Array<String>] Paths to spec files or directories
        # @return [self]
        def start(spec_paths)
          raise "Already running" if @status == :running

          @status = :running
          @spec_paths = spec_paths
          @completed_examples = []
          @failure_count = 0

          self
        end

        # Execute the run (must be called in Async context)
        # @param task [Async::Task] Parent async task
        # @return [RunResult]
        def execute(task:)
          raise "Not started" unless @status == :running

          # Phase 1: Discover examples
          begin
            examples = ExampleDiscovery.discover(@spec_paths)
            @total_examples = examples.size
          rescue ExampleDiscovery::DiscoveryError => e
            @status = :failed
            @results = RunResult.new(
              success: false,
              error:   "Example discovery failed: #{e.message}"
            )
            return @results
          end

          return empty_result if examples.empty?

          # Phase 2: Partition across workers
          partitions = Partitioner.partition(examples, @worker_count)
          actual_count = partitions.count { |p| !p.empty? }

          return empty_result if actual_count == 0

          # Phase 3: Spawn workers
          @worker_group = AsyncWorkers::WorkerGroup.new(
            size:    actual_count,
            command: worker_command,
            env:     {},
            rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
          )
          @worker_group.start(task: task)

          # Phase 4: Set up notification handlers
          setup_notification_handlers

          # Phase 5: Dispatch work
          responses = dispatch_work(task, partitions)

          # Phase 6: Aggregate results
          @results = aggregate_results(responses)
          @status = @results.success? ? :completed : :failed

          # Phase 7: Cleanup
          @worker_group.stop(timeout: 5)

          @results

        rescue AsyncWorkers::WorkerFailure => e
          @status = :failed
          @results = RunResult.new(
            success: false,
            error:   "Worker #{e.worker_index} crashed: #{e.exit_status}"
          )
          @worker_group&.kill
          @results
        end

        # Block until run completes
        # @return [RunResult]
        def wait
          @results
        end

        # Query current progress
        # @return [Hash] { completed:, total:, failures:, status: }
        def progress
          @mutex.synchronize do
            {
              completed: @completed_examples.size,
              total:     @total_examples,
              failures:  @failure_count,
              status:    @status
            }
          end
        end

        # Cancel the current run
        def cancel
          return unless @status == :running

          @status = :cancelled
          @worker_group&.kill
        end

        private

        def worker_command
          # Use the unified CLI in worker mode
          cli_path = File.expand_path("../../../../bin/rspec-agents", __dir__)
          [RbConfig.ruby, cli_path, "worker"]
        end

        def setup_notification_handlers
          @worker_group.each_with_index do |worker, i|
            worker.rpc.on_notification { |msg| handle_notification(i, msg) }
            worker.stderr.on_data { |line| handle_worker_stderr(i, line) }
            worker.stdout.on_data { |line| handle_worker_stdout(i, line) }
          end
        end

        def dispatch_work(task, partitions)
          # Send run_specs request to each worker in parallel
          tasks = @worker_group.workers.zip(partitions).map do |worker, examples|
            next if examples.nil? || examples.empty?

            task.async do
              worker.rpc.request({
                action:      "run_specs",
                example_ids: examples.map(&:id)
              })
            end
          end

          tasks.compact.map(&:wait)
        end

        def handle_notification(worker_index, msg)
          return unless msg[:type] == "event"

          event_type = msg[:event_type]
          payload = msg[:payload] || {}
          example_id = payload[:example_id]

          # Include worker_index in payload for UI routing
          payload_with_worker = payload.merge(worker_index: worker_index)

          @mutex.synchronize do
            # Buffer event
            @example_buffers[example_id] << { type: event_type, payload: payload_with_worker }

            # Check for example completion
            if completion_event?(event_type)
              flush_example_buffer(example_id)
              @completed_examples << example_id
              @failure_count += 1 if event_type == "ExampleFailed"

              notify_progress

              # Fail-fast check
              if @fail_fast && event_type == "ExampleFailed"
                cancel
              end
            end
          end

          # Fire callbacks outside mutex
          @event_callbacks.each { |cb| cb.call(event_type, payload_with_worker) }
        end

        def completion_event?(type)
          ["ExamplePassed", "ExampleFailed", "ExamplePending"].include?(type)
        end

        def flush_example_buffer(example_id)
          # Remove buffer - events were already emitted via callbacks
          @example_buffers.delete(example_id)
        end

        def notify_progress
          @progress_callbacks.each do |cb|
            cb.call(@completed_examples.size, @total_examples, @failure_count)
          end
        end

        def handle_worker_stderr(worker_index, line)
          @event_callbacks.each do |cb|
            cb.call("WorkerLog", { worker_index: worker_index, line: line.chomp, stream: "stderr" })
          end
        end

        def handle_worker_stdout(worker_index, line)
          @event_callbacks.each do |cb|
            cb.call("WorkerLog", { worker_index: worker_index, line: line.chomp, stream: "stdout" })
          end
        end

        def aggregate_results(responses)
          total = 0
          failures = 0

          responses.each do |r|
            next unless r
            total += r[:example_count] || 0
            failures += r[:failure_count] || 0
          end

          RunResult.new(
            success:            failures == 0,
            example_count:      total,
            failure_count:      failures,
            completed_examples: @completed_examples.dup
          )
        end

        def empty_result
          @status = :completed
          @results = RunResult.new(success: true)
        end
      end
    end
  end
end
