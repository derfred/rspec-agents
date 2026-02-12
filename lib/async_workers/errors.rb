# frozen_string_literal: true

module AsyncWorkers
  # Base error class for all AsyncWorkers errors
  class Error < StandardError; end

  # Raised when attempting to send on a closed RPC channel,
  # or when a pending request's channel closes
  class ChannelClosedError < Error; end

  # Raised by WorkerGroup when any worker exits with non-zero status
  class WorkerFailure < Error
    attr_reader :worker_index, :exit_status

    def initialize(worker_index:, exit_status:)
      @worker_index = worker_index
      @exit_status  = exit_status
      super("Worker #{worker_index} failed with status #{exit_status.exitstatus}")
    end
  end
end
