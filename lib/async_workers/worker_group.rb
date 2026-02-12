# frozen_string_literal: true

require "async"
require_relative "errors"
require_relative "channel_config"
require_relative "managed_process"

module AsyncWorkers
  # Coordinates multiple identical workers in a fan-out pattern.
  # Provides fail-fast semantics: if any worker exits with non-zero status,
  # all other workers are killed immediately.
  #
  # @example Fan-out work to multiple workers
  #   Async do |task|
  #     group = WorkerGroup.new(
  #       size: 4,
  #       command: ['ruby', 'worker.rb'],
  #       rpc: ChannelConfig.stdio_rpc
  #     )
  #
  #     group.start(task: task)
  #
  #     # Set up handlers
  #     group.each_with_index do |worker, i|
  #       worker.stderr.on_data { |line| puts "[worker-#{i}] #{line}" }
  #     end
  #
  #     # Fan-out work
  #     results = group.map do |worker|
  #       worker.rpc.request({ action: 'process', data: '...' })
  #     end
  #
  #     group.stop
  #   end
  #
  class WorkerGroup
    include Enumerable

    # @return [Array<ManagedProcess>] All workers
    attr_reader :workers
    alias_method :to_a, :workers

    # @return [Integer] Number of workers
    attr_reader :size

    # @return [WorkerFailure, nil] First failure encountered
    attr_reader :failure

    # @param size [Integer] Number of workers to spawn
    # @param command [Array<String>] Command to execute for each worker
    # @param env [Hash] Base environment variables (WORKER_INDEX added automatically)
    # @param rpc [ChannelConfig] RPC configuration
    def initialize(size:, command:, env: {}, rpc: ChannelConfig.no_rpc)
      @size              = size
      @command           = command
      @base_env          = env
      @rpc_config        = rpc
      @stopping          = false
      @failure           = nil
      @failure_condition = nil
      @failure_mutex     = Mutex.new

      @workers = size.times.map do |i|
        ManagedProcess.new(
          command: command,
          env:     env.merge("WORKER_INDEX" => i.to_s),
          rpc:     rpc
        )
      end
    end

    # Spawn all workers.
    # @param task [Async::Task] Parent async task
    def start(task:)
      @failure_condition = Async::Condition.new

      @workers.each_with_index do |worker, i|
        worker.on_exit do |status|
          handle_worker_exit(i, status) unless @stopping
        end
        worker.start(task: task)
      end
    end

    # Access worker by index.
    # @param index [Integer] Worker index
    # @return [ManagedProcess]
    def [](index)
      @workers[index]
    end

    # Iterate over workers.
    # @yield [ManagedProcess] Each worker
    def each(&block)
      @workers.each(&block)
    end

    # Graceful shutdown of all workers (parallel).
    # @param timeout [Numeric] Timeout per worker
    def stop(timeout: 5)
      @stopping = true

      # Stop all workers - if we're in an Async context, run in parallel
      if Async::Task.current?
        tasks = @workers.map do |worker|
          Async::Task.current.async { worker.stop(timeout: timeout) }
        end
        tasks.each(&:wait)
      else
        # Not in async context, stop sequentially
        @workers.each { |worker| worker.stop(timeout: timeout) }
      end
    end

    # Immediate kill of all workers.
    def kill
      @stopping = true
      @workers.each(&:kill)
    end

    # Block until all workers exit.
    # @param timeout [Numeric, nil] Optional timeout in seconds
    # @return [Array<Process::Status>] Exit statuses of all workers
    # @raise [Async::TimeoutError] If timeout exceeded
    def wait(timeout: nil)
      if timeout
        Async::Task.current.with_timeout(timeout) do
          @workers.map(&:wait)
        end
      else
        @workers.map(&:wait)
      end
    end

    # Check if all workers are running.
    # @return [Boolean]
    def alive?
      @workers.all?(&:alive?)
    end

    # Check if any worker has failed.
    # @return [Boolean]
    def failed?
      !@failure.nil?
    end

    # Block until a worker fails.
    # @return [WorkerFailure] The failure exception
    def wait_for_failure
      @failure_condition.wait
    end

    private

    def handle_worker_exit(index, status)
      return if status.nil? || status.success?

      # Use mutex to ensure only first failure is recorded
      first_failure = @failure_mutex.synchronize do
        return if @failure # Already handling a failure
        @failure = WorkerFailure.new(worker_index: index, exit_status: status)
      end

      return unless first_failure

      @failure_condition.signal(@failure)

      # Kill all other workers
      @stopping = true
      @workers.each_with_index do |worker, i|
        worker.kill if i != index && worker.alive?
      end
    end
  end
end
