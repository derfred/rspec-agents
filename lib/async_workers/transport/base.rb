# frozen_string_literal: true

module AsyncWorkers
  module Transport
    # Abstract base class for transport implementations.
    # Transports handle raw I/O for RPC messages.
    class Base
      # Spawn the child process
      # @return [Integer] Process ID
      def spawn
        raise NotImplementedError, "#{self.class}#spawn must be implemented"
      end

      # Send a line to the transport (without newline)
      # @param line [String] Line to send
      def write_line(line)
        raise NotImplementedError, "#{self.class}#write_line must be implemented"
      end

      # Read a line from the transport
      # @return [String, nil] Line read (without newline) or nil on EOF
      def read_line
        raise NotImplementedError, "#{self.class}#read_line must be implemented"
      end

      # Get the stderr reader IO for log capture
      # @return [IO]
      def stderr_reader
        raise NotImplementedError, "#{self.class}#stderr_reader must be implemented"
      end

      # Close the transport
      def close
        raise NotImplementedError, "#{self.class}#close must be implemented"
      end

      # Check if transport is closed
      # @return [Boolean]
      def closed?
        raise NotImplementedError, "#{self.class}#closed? must be implemented"
      end

      # Get the process ID
      # @return [Integer, nil]
      def pid
        raise NotImplementedError, "#{self.class}#pid must be implemented"
      end

      # Wait for the process to exit and return exit status.
      # This is a blocking call.
      # @return [Process::Status]
      def wait_for_exit
        raise NotImplementedError, "#{self.class}#wait_for_exit must be implemented"
      end
    end
  end
end
