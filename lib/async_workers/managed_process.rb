# frozen_string_literal: true

require "async"
require_relative "errors"
require_relative "channel_config"
require_relative "output_stream"
require_relative "rpc_channel"
require_relative "transport/stdio_transport"
require_relative "transport/unix_socket_transport"

module AsyncWorkers
  # Wraps a single child process with lifecycle management and communication.
  # Provides process spawning, RPC communication, output streaming, and health monitoring.
  #
  # @example Basic usage with RPC
  #   Async do |task|
  #     process = ManagedProcess.new(
  #       command: ['ruby', 'worker.rb'],
  #       rpc: ChannelConfig.stdio_rpc
  #     )
  #
  #     process.stderr.on_data { |line| puts "[worker] #{line}" }
  #     process.start(task: task)
  #
  #     result = process.rpc.request({ action: 'compute', x: 42 })
  #     process.stop
  #   end
  #
  class ManagedProcess
    # @return [Integer, nil] Process ID
    attr_reader :pid

    # @return [Symbol] :pending, :running, :stopping, :exited
    attr_reader :status

    # @return [Process::Status, nil] Exit status (nil until exited)
    attr_reader :exit_status

    # @return [RpcChannel, nil] RPC channel (nil if no_rpc)
    attr_reader :rpc

    # @return [OutputStream] stderr line stream
    attr_reader :stderr

    # @return [OutputStream] stdout line stream (empty if stdio_rpc mode)
    attr_reader :stdout

    # @param command [Array<String>] Command to execute
    # @param env [Hash] Environment variables
    # @param chdir [String, nil] Working directory for the process
    # @param rpc [ChannelConfig] RPC configuration
    # @param health_check_interval [Numeric] Health polling interval in seconds
    def initialize(command:, env: {}, chdir: nil, rpc: ChannelConfig.no_rpc, health_check_interval: 0.5)
      @command    = command
      @env        = env
      @chdir      = chdir
      @rpc_config = rpc
      @health_check_interval = health_check_interval

      @status         = :pending
      @pid            = nil
      @exit_status    = nil
      @transport      = nil
      @rpc            = nil
      @stderr         = OutputStream.new
      @stdout         = OutputStream.new
      @exit_callbacks = []
      @exit_condition = nil
      @exited_mutex   = Mutex.new
    end

    # Spawn process and begin monitoring.
    # @param task [Async::Task] Parent async task
    def start(task:)
      raise "Process already started" unless @status == :pending

      @exit_condition = Async::Condition.new

      # Create appropriate transport
      @transport = create_transport
      @pid       = @transport.spawn
      @status    = :running

      # Set up RPC if enabled
      if @rpc_config.rpc_enabled?
        @rpc = RpcChannel.new(@transport)
        @rpc.start(task: task)
      end

      # Start output readers
      start_output_readers(task)

      # Start health monitor
      start_health_monitor(task)
    end

    # Graceful shutdown: RPC shutdown -> SIGTERM -> SIGKILL.
    # @param timeout [Numeric] Total timeout for shutdown
    def stop(timeout: 5)
      return if @status == :exited

      @status      = :stopping
      half_timeout = timeout / 2.0

      # Step 1: RPC shutdown request
      if @rpc && !@rpc.closed?
        @rpc.shutdown(timeout: half_timeout)
      end

      # Step 2: Wait for process to exit after RPC shutdown, or send SIGTERM
      if alive?
        begin
          wait(timeout: half_timeout)
        rescue Async::TimeoutError
          # Process didn't exit after RPC shutdown, send SIGTERM
          send_signal(:TERM)
          begin
            wait(timeout: half_timeout)
          rescue Async::TimeoutError
            # Continue to SIGKILL
          end
        end
      end

      # Step 3: SIGKILL if still alive
      if alive?
        send_signal(:KILL)
        wait
      end

      # Ensure we have exit status if process exited but health monitor hasn't run
      collect_exit_status_if_needed

      cleanup
    end

    # Immediate SIGKILL.
    def kill
      return unless alive?
      send_signal(:KILL)
      wait
      cleanup
    end

    # Send arbitrary signal to the process.
    # @param signal [Symbol, Integer] Signal to send (e.g., :TERM, :KILL, 9)
    def send_signal(signal)
      return unless @pid && alive?
      Process.kill(signal, @pid)
    rescue Errno::ESRCH
      # Process already gone
    end

    # Check if process is running.
    # @return [Boolean]
    def alive?
      return false unless @pid
      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # Block (yield fiber) until process exits.
    # @param timeout [Numeric, nil] Optional timeout in seconds
    # @return [Process::Status] Exit status
    # @raise [Async::TimeoutError] If timeout exceeded
    def wait(timeout: nil)
      return @exit_status if @status == :exited

      if timeout
        Async::Task.current.with_timeout(timeout) { @exit_condition.wait }
      else
        @exit_condition.wait
      end

      @exit_status
    end

    # Register exit callback.
    # @yield [Process::Status] Called when process exits
    def on_exit(&block)
      @exit_callbacks << block
    end

    private

    def create_transport
      case @rpc_config.mode
      when :stdio_rpc
        Transport::StdioTransport.new(command: @command, env: @env, chdir: @chdir)
      when :unix_socket_rpc
        Transport::UnixSocketTransport.new(command: @command, env: @env, chdir: @chdir)
      when :no_rpc
        Transport::StdioTransport.new(command: @command, env: @env, chdir: @chdir)
      end
    end

    def start_output_readers(task)
      # Always read stderr
      task.async do
        while (line = @transport.stderr_reader.gets)
          @stderr.emit(line.chomp)
        end
      rescue IOError
        # Stream closed
      ensure
        @stderr.close
      end

      # Read stdout if not used for RPC (unix_socket or no_rpc mode)
      unless @rpc_config.stdio?
        stdout_reader = @transport.respond_to?(:stdout_reader) ? @transport.stdout_reader : nil
        if stdout_reader
          task.async do
            while (line = stdout_reader.gets)
              @stdout.emit(line.chomp)
            end
          rescue IOError
            # Stream closed
          ensure
            @stdout.close
          end
        end
      end
    end

    def start_health_monitor(task)
      task.async do
        loop do
          sleep(@health_check_interval)

          # Check if process is still alive
          unless alive?
            # Process has exited, collect status via transport
            @exit_status = @transport&.wait_for_exit
            handle_exit
            break
          end
        end
      end
    end

    def handle_exit
      # Use mutex to ensure we only handle exit once
      already_exited = @exited_mutex.synchronize do
        was_exited = @status == :exited
        @status = :exited unless was_exited
        was_exited
      end
      return if already_exited

      @rpc&.close
      @transport&.close

      @exit_condition.signal(@exit_status)

      @exit_callbacks.each do |cb|
        cb.call(@exit_status)
      rescue => e
        warn "[AsyncWorkers::ManagedProcess] Exit callback error: #{e.class}: #{e.message}"
      end
    end

    def cleanup
      @rpc&.close
      @transport&.close
      @stderr.close
      @stdout.close
      @exited_mutex.synchronize { @status = :exited }
    end

    def collect_exit_status_if_needed
      return if @exit_status

      # Use transport's wait_for_exit which handles process reaping properly
      status = @transport&.wait_for_exit
      if status
        @exit_status = status
        handle_exit
      end
    end
  end
end
