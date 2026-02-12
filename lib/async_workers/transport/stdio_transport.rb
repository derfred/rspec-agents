# frozen_string_literal: true

require "open3"
require_relative "base"
require_relative "../errors"

module AsyncWorkers
  module Transport
    # Transport over stdin/stdout using Open3.popen3.
    # RPC messages go over stdin (write) and stdout (read).
    # Stderr is available separately for log capture.
    class StdioTransport < Base
      attr_reader :wait_thread

      # @param command [Array<String>] Command to execute
      # @param env [Hash] Environment variables
      # @param chdir [String, nil] Working directory for the process
      def initialize(command:, env: {}, chdir: nil)
        @command     = command
        @env         = env
        @chdir       = chdir
        @closed      = false
        @stdin       = nil
        @stdout      = nil
        @stderr      = nil
        @wait_thread = nil
      end

      # Spawn the process using Open3.popen3
      # @return [Integer] PID
      def spawn
        spawn_opts = {}
        spawn_opts[:chdir] = @chdir if @chdir

        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@env, *@command, **spawn_opts)

        # Enable sync for proper fiber scheduling
        @stdin.sync  = true
        @stdout.sync = true
        @stderr.sync = true

        @wait_thread.pid
      end

      def write_line(line)
        raise ChannelClosedError, "Transport closed" if @closed
        @stdin.puts(line)
        @stdin.flush
      end

      def read_line
        return nil if @closed
        line = @stdout.gets
        return nil if line.nil?
        line.chomp
      end

      def stderr_reader
        @stderr
      end

      def stdout_reader
        @stdout
      end

      def close
        return if @closed
        @closed = true

        @stdin&.close rescue nil
        @stdout&.close rescue nil
        @stderr&.close rescue nil
      end

      def closed?
        @closed
      end

      def pid
        @wait_thread&.pid
      end

      # Wait for the process to exit and return exit status.
      # Uses Open3's wait_thread which handles process reaping.
      # @return [Process::Status]
      def wait_for_exit
        @wait_thread&.value
      end
    end
  end
end
