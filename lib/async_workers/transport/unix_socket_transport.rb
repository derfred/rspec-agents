# frozen_string_literal: true

require "socket"
require "open3"
require_relative "base"
require_relative "../errors"

module AsyncWorkers
  module Transport
    # Transport over Unix domain socket using socketpair.
    # RPC messages go over the socket.
    # Both stdout and stderr are available for log capture.
    class UnixSocketTransport < Base
      attr_reader :wait_thread

      # @param command [Array<String>] Command to execute
      # @param env [Hash] Environment variables
      # @param chdir [String, nil] Working directory for the process
      def initialize(command:, env: {}, chdir: nil)
        @command       = command
        @env           = env
        @chdir         = chdir
        @closed        = false
        @parent_socket = nil
        @child_socket  = nil
        @stdout        = nil
        @stderr        = nil
        @wait_thread   = nil
      end

      # Spawn the process with socket pair for RPC.
      # Child receives RPC_SOCKET_FD environment variable.
      # @return [Integer] PID
      def spawn
        # Create socket pair - parent and child ends
        @parent_socket, @child_socket = Socket.pair(:UNIX, :STREAM, 0)

        child_fd = @child_socket.fileno

        # Prepare environment with socket fd
        spawn_env = @env.merge("RPC_SOCKET_FD" => child_fd.to_s)

        # Use Open3.popen3 with extra spawn options to inherit the socket fd
        spawn_opts = { child_fd => child_fd, close_others: false }
        spawn_opts[:chdir] = @chdir if @chdir

        stdin, @stdout, @stderr, @wait_thread = Open3.popen3(
          spawn_env,
          *@command,
          **spawn_opts
        )

        # Close stdin since we use socket for RPC
        stdin.close
        # Close child end of socket in parent
        @child_socket.close

        @parent_socket.sync = true
        @stdout.sync = true
        @stderr.sync = true

        @wait_thread.pid
      end

      def write_line(line)
        raise ChannelClosedError, "Transport closed" if @closed
        @parent_socket.puts(line)
        @parent_socket.flush
      end

      def read_line
        return nil if @closed
        line = @parent_socket.gets
        return nil if line.nil?
        line.chomp
      end

      # @return [IO] stdout stream (available for logs in socket mode)
      def stdout_reader
        @stdout
      end

      def stderr_reader
        @stderr
      end

      def close
        return if @closed
        @closed = true

        @parent_socket&.close rescue nil
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
