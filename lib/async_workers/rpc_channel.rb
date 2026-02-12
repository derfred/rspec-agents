# frozen_string_literal: true

require "json"
require "securerandom"
require "async"
require_relative "errors"
require_relative "output_stream"

module AsyncWorkers
  # JSON-RPC message framing and request/response correlation.
  # Handles bidirectional communication with newline-delimited JSON.
  class RpcChannel
    SHUTDOWN_ACTION = "__shutdown__"

    # @return [OutputStream] Incoming notifications (messages without reply_to)
    attr_reader :notifications

    # @param transport [Transport::Base] Underlying transport
    def initialize(transport)
      @transport        = transport
      @pending_requests = {}
      @mutex            = Mutex.new
      @closed           = false
      @notifications    = OutputStream.new
      @reader_task      = nil
    end

    # Start the reader task to process incoming messages.
    # Must be called after the process is started.
    # @param task [Async::Task] Parent task
    def start(task:)
      @reader_task = task.async { reader_loop }
    end

    # Send request and wait for response.
    # @param payload [Hash] Request payload
    # @param timeout [Numeric, nil] Optional timeout in seconds
    # @return [Hash] Response payload
    # @raise [ChannelClosedError] If channel is closed
    # @raise [Async::TimeoutError] If timeout exceeded
    def request(payload, timeout: nil)
      raise ChannelClosedError, "Channel closed" if @closed

      id = SecureRandom.uuid
      condition = Async::Condition.new

      @mutex.synchronize do
        @pending_requests[id] = { condition: condition, response: nil }
      end

      send_message(payload.merge(id: id))

      begin
        if timeout
          Async::Task.current.with_timeout(timeout) { condition.wait }
        else
          condition.wait
        end
      rescue Async::TimeoutError
        @mutex.synchronize { @pending_requests.delete(id) }
        raise
      end

      entry = @mutex.synchronize { @pending_requests.delete(id) }
      response = entry&.fetch(:response, nil)
      raise ChannelClosedError, "Channel closed while waiting" if response.nil? && @closed

      response
    end

    # Send fire-and-forget notification.
    # @param payload [Hash] Notification payload (should not have id field)
    def notify(payload)
      raise ChannelClosedError, "Channel closed" if @closed
      send_message(payload.reject { |k, _| k == :id || k == "id" })
    end

    # Request graceful shutdown via protocol.
    # Sends __shutdown__ action and waits for acknowledgment.
    # @param timeout [Numeric] Timeout for shutdown acknowledgment
    # @return [Hash, nil] Shutdown response or nil on timeout
    def shutdown(timeout: 5)
      return nil if @closed

      begin
        request({ action: SHUTDOWN_ACTION }, timeout: timeout)
      rescue Async::TimeoutError
        nil
      end
    end

    # Register callback for notifications (convenience method).
    # @yield [Hash] Notification payload
    def on_notification(&block)
      @notifications.on_data(&block)
    end

    # Check if channel is closed.
    # @return [Boolean]
    def closed?
      @closed
    end

    # Close the channel.
    # Signals all pending requests and stops the reader.
    def close
      return if @closed
      @closed = true

      # Signal all pending requests so they don't hang
      @mutex.synchronize do
        @pending_requests.each_value do |pending|
          pending[:condition].signal
        end
        @pending_requests.clear
      end

      @notifications.close
      @reader_task&.stop
    end

    private

    def send_message(payload)
      @transport.write_line(payload.to_json)
    end

    def reader_loop
      while (line = @transport.read_line)
        begin
          message = JSON.parse(line, symbolize_names: true)
          handle_incoming(message)
        rescue JSON::ParserError => e
          warn "[AsyncWorkers::RpcChannel] JSON parse error: #{e.message}"
        end
      end
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      # Transport closed
    ensure
      close
    end

    def handle_incoming(message)
      if message[:reply_to]
        # Response to a request
        @mutex.synchronize do
          pending = @pending_requests[message[:reply_to]]
          if pending
            pending[:response] = message
            pending[:condition].signal
          end
        end
      else
        # Notification (no reply_to field)
        @notifications.emit(message)
      end
    end
  end
end
